// AI Quota Watch anonymous collector (Cloudflare Worker).
// POST /v1/report  {install, reports[]}  -> stores sanitized reports under an anonymous reporter id.
// GET  /v1/export  (Bearer EXPORT_TOKEN) -> every stored report, for the GitHub Action that builds the stats.
// POST /v1/forget  {install}            -> deletes every report this install sent (right to erasure).
// No IP address, GitHub account or install id is stored: the reporter id is HMAC(SALT, install id), and
// rate limits use HMAC(SALT, /24 or /48 network + day) counters that expire after a day.
// Report keys are r:<reporter>:<day>:<uuid>, so /v1/forget is a prefix list; batches per day are capped per class
// (reporters not yet on record / reporters on record, see LIMITS).
// Each stored report also carries reporterFirstSeen (the day this reporter id was first seen; the record expires
// keepDays after that), receivedDay (the day the collector received it) and ipGroup (8 hex characters of
// HMAC(SALT, /24 or /48 network + day), so it changes every day and cannot be turned back into an address).
// The aggregation step uses them to discount brand-new reporters and reporters sharing a network on the same day.

import { sanitize, hourOf } from "./schema.js";
export { sanitize };
// KV write budget (Cloudflare free plan: 1,000 writes a day per account; deletes count as writes), by worst case per class:
//   known reporter batch (rl:day:known, rl:in, r:)                      3 writes x 40 batches = 120
//   new reporter batch (those plus rl:ip, rs:, rl:new)                  6 writes x 15 batches =  90
//   forget (ip counter, day counter, up to 31 days x 3 batches + rs: = 94 deletes)  96 writes x 5 = 480
//   visit hits                                                          VISIT_WRITE_CAP      = 150
//   slack (visit overshoot across data centers, rollups, counters of rejected batches)   = 160
// 120 + 90 + 480 + 150 + 160 = 1000. The two batch counters are separate so ids minted to fill the new class cannot use up
// the budget of reporters already on record. Forget gets the largest share so people can always delete their data; a
// typical forget deletes far fewer than 94 keys. If traffic grows, the paid KV plan (millions of writes) lifts all of this.
export const LIMITS = { bodyBytes: 20000, reports: 30, perInstallPerDay: 3, perIpPerDay: 20, newReportersPerIpPerDay: 2, keepDays: 31,
  newBatchesPerDay: 15, knownBatchesPerDay: 40, forgetsPerDay: 5, slackWrites: 160 };
// Old-format report keys (r:<day>:...) are no longer written and expire within 31 days of this change, so /v1/forget
// walks them only until this day.
export const LEGACY_KEYS_UNTIL = "2026-12-08";
const ALLOWED_ORIGINS = ["https://aiquotawatch.pages.dev", "https://dwagwd.github.io", "http://127.0.0.1:8765", "http://localhost:8765"];
// The allowed origins that are websites (not a local dev server): only requests from these may be labelled via "site".
const SITE_ORIGINS = ALLOWED_ORIGINS.filter((o) => !["localhost", "127.0.0.1"].includes(new URL(o).hostname));


async function hmac(secret, text) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// The coarse network an address belongs to: the /24 for IPv4, the /48 for IPv6. Only ever used inside an HMAC.
export function ipPrefix(ip) {
  const s = String(ip || "").trim().toLowerCase();
  const v4 = s.match(/^(?:::ffff:)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$/);
  if (v4) return "v4:" + v4.slice(1, 4).map(Number).join(".");
  if (!s.includes(":") || !/^[0-9a-f:]+$/.test(s)) return "other:" + s;
  const [head, tail] = s.split("::");
  const a = head ? head.split(":") : [];
  const b = tail !== undefined && tail ? tail.split(":") : [];
  const parts = tail !== undefined ? [...a, ...Array(Math.max(0, 8 - a.length - b.length)).fill("0"), ...b] : a;
  return "v6:" + parts.slice(0, 3).map((p) => (parseInt(p || "0", 16) || 0).toString(16)).join(":");
}

function cors(request) {
  const origin = request.headers.get("Origin");
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    Object.assign(headers, { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type", "Vary": "Origin" });
  }
  return headers;
}
const json = (request, status, body) => new Response(JSON.stringify(body), { status, headers: cors(request) });
// HTTP 429 with a machine-readable flag, so clients need not match the message.
const full = (request) => json(request, 429, { error: "collector is full for today", full: true });

// Rate-limit counters are read-modify-write, so simultaneous submissions from the same install or IP can each
// pass before the other's increment lands. They limit abuse, not exact counts; the aggregation step separately
// caps reports per reporter per day and requires distinct reporters before publishing.
async function bump(kv, key, limit) {
  const n = Number(await kv.get(key)) || 0;
  if (n >= limit) return false;
  await kv.put(key, String(n + 1), { expirationTtl: 86400 });
  return true;
}

async function report(request, env) {
  const length = Number(request.headers.get("Content-Length") || 0);
  if (length > LIMITS.bodyBytes) return json(request, 413, { error: "too large" });
  const text = await request.text();
  if (text.length > LIMITS.bodyBytes) return json(request, 413, { error: "too large" });
  let body;
  try { body = JSON.parse(text); } catch { return json(request, 400, { error: "invalid JSON" }); }
  const install = typeof body?.install === "string" && /^[A-Za-z0-9-]{16,64}$/.test(body.install) ? body.install : null;
  if (!install) return json(request, 400, { error: "missing install id" });
  // Reports must describe the last 8 days, not the future or older days that are already published.
  const nowMs = Date.now();
  const recent = (r) => !r.date || (Date.parse(r.date) <= nowMs + 3600e3 && Date.parse(r.date) >= nowMs - 8 * 864e5);
  const reports = (Array.isArray(body.reports) ? body.reports : []).slice(0, LIMITS.reports).map(sanitize).filter(Boolean).filter(recent);
  if (!reports.length) return json(request, 400, { error: "no valid reports" });

  const day = new Date().toISOString().slice(0, 10);
  const reporter = "anon-" + (await hmac(env.SALT, "install:" + install)).slice(0, 16);
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  // Network limits use the /24 (IPv4) or /48 (IPv6), so one host cannot get a fresh budget per address.
  const net = ipPrefix(ip);
  const ipKey = "rl:ip:" + (await hmac(env.SALT, "ip:" + net + ":" + day)).slice(0, 32);
  const installKey = "rl:in:" + day + ":" + reporter;
  // A reporter is new when it has no first-seen record. Each IP address may introduce only a few new reporters a
  // day, so minting install ids cannot cheaply produce "distinct reporters". Reporters already on record are never
  // capped here, so people behind a shared address keep working. Both keys are only written when a reporter is
  // new, so ordinary submissions cost no extra KV writes.
  const seenKey = "rs:" + reporter;
  const firstSeen = await env.REPORTS.get(seenKey);
  // Global caps on accepted batches per UTC day, one counter per class (reporter on record / not yet on record),
  // checked before anything is written. The counter is incremented below, only once the batch has passed every other limit.
  const dayKey = "rl:day:" + (firstSeen ? "known" : "new") + ":" + day;
  const acceptedToday = Number(await env.REPORTS.get(dayKey)) || 0;
  if (acceptedToday >= (firstSeen ? LIMITS.knownBatchesPerDay : LIMITS.newBatchesPerDay)) return full(request);
  const newKey = "rl:new:" + (await hmac(env.SALT, "ip-new:" + net + ":" + day)).slice(0, 32);
  let introduced = 0;
  if (!firstSeen) {
    introduced = Number(await env.REPORTS.get(newKey)) || 0;
    if (introduced >= LIMITS.newReportersPerIpPerDay) return json(request, 429, { error: "too many new installs from this network today" });
  }
  // The per-install limit comes first so a looping install does not burn its network's budget. The network counter is
  // only written for new reporters: reporters on record are covered by their own install limit, and minting new ones
  // is held back by the new-reporter limit, so skipping it saves a KV write per batch.
  if (!(await bump(env.REPORTS, installKey, LIMITS.perInstallPerDay)) || (!firstSeen && !(await bump(env.REPORTS, ipKey, LIMITS.perIpPerDay)))) {
    return json(request, 429, { error: "daily limit reached" });
  }
  if (!firstSeen) {
    await env.REPORTS.put(seenKey, day, { expirationTtl: LIMITS.keepDays * 86400 });
    await env.REPORTS.put(newKey, String(introduced + 1), { expirationTtl: 2 * 86400 });
  }
  const ipGroup = (await hmac(env.SALT, "ipgrp:" + ipPrefix(ip) + ":" + day)).slice(0, 8);
  const now = hourOf(new Date().toISOString());
  // `via` is client-chosen, so it is decided here: "site" only for requests from one of our websites (by Origin),
  // and a client-sent "site" from anywhere else becomes "quotapilot".
  const fromSite = SITE_ORIGINS.includes(request.headers.get("Origin") || "");
  const stored = reports.map((r) => ({ ...r, via: fromSite ? "site" : (r.via && r.via !== "site" ? r.via : "quotapilot"),
    date: r.date || now, reporter, reporterFirstSeen: firstSeen || day, receivedDay: day, ipGroup }));
  await env.REPORTS.put(dayKey, String(acceptedToday + 1), { expirationTtl: 86400 });
  // The reporter id leads the key so /v1/forget can find this install's reports with a prefix list.
  await env.REPORTS.put("r:" + reporter + ":" + day + ":" + crypto.randomUUID(), JSON.stringify(stored), { expirationTtl: LIMITS.keepDays * 86400 });
  return json(request, 200, { ok: true, accepted: stored.length });
}

// Deletes everything one install has sent: its reports (a prefix list on r:<reporter>:, plus a cursor scan of all
// older date-prefixed keys, which are no longer written and expire within 31 days) and its first-seen record.
// Only the install id itself can ask, and it never leaves the
// sender's machine except in this request; a few requests per network per day are allowed.
async function forget(request, env) {
  let body;
  try { body = JSON.parse((await request.text()).slice(0, 2000)); } catch { return json(request, 400, { error: "invalid JSON" }); }
  const install = typeof body?.install === "string" && /^[A-Za-z0-9-]{16,64}$/.test(body.install) ? body.install : null;
  if (!install) return json(request, 400, { error: "missing install id" });
  const day = new Date(Date.now()).toISOString().slice(0, 10);
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const reporter = "anon-" + (await hmac(env.SALT, "install:" + install)).slice(0, 16);
  // Cheap checks first (reads only): the first-seen record and every key this install owns. When nothing is found the
  // answer is deleted:0 and no counter is touched, so unknown ids cannot use up the forget budget.
  const known = await env.REPORTS.get("rs:" + reporter);
  const names = [];
  let cursor;
  do {
    const page = await env.REPORTS.list({ prefix: "r:" + reporter + ":", cursor, limit: 1000 });
    names.push(...page.keys.map((k) => k.name));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  // Older formats r:<day>:<reporter>:<uuid> and r:<day>:<uuid> start with a date ("r:20..."). They are no longer
  // written and have all expired by LEGACY_KEYS_UNTIL, so they are walked (every page, with the cursor) only until then.
  let oldCursor;
  if (day < LEGACY_KEYS_UNTIL) do {
    const old = await env.REPORTS.list({ prefix: "r:20", cursor: oldCursor, limit: 1000 });
    for (const k of old.keys) {
      const parts = k.name.split(":");
      let mine = parts.length === 4 ? parts[2] === reporter : false;
      if (parts.length === 3) {
        const v = await env.REPORTS.get(k.name);
        try { mine = !!v && JSON.parse(v).some((r) => r.reporter === reporter); } catch { mine = false; }
      }
      if (mine) names.push(k.name);
    }
    oldCursor = old.list_complete ? undefined : old.cursor;
  } while (oldCursor);
  if (!names.length && !known) return json(request, 200, { ok: true, deleted: 0 });
  // Only a forget that deletes something counts. A small global daily cap (counted in the LIMITS write budget) is checked
  // first so a refused request deletes and writes nothing; the per-network counter uses the /24 or /48 like the other limits.
  const forgetKey = "rl:forget-day:" + day;
  const forgetsToday = Number(await env.REPORTS.get(forgetKey)) || 0;
  if (forgetsToday >= LIMITS.forgetsPerDay) return full(request);
  if (!(await bump(env.REPORTS, "rl:forget:" + (await hmac(env.SALT, "forget:" + ipPrefix(ip) + ":" + day)).slice(0, 32), 5))) {
    return json(request, 429, { error: "daily limit reached" });
  }
  await env.REPORTS.put(forgetKey, String(forgetsToday + 1), { expirationTtl: 86400 });
  for (const name of names) await env.REPORTS.delete(name);
  await env.REPORTS.delete("rs:" + reporter);
  return json(request, 200, { ok: true, deleted: names.length });
}

// Visitor counting without cookies. Each visit is its own short-lived key,
//   hit:<day>:<visitor>:<random>   (expires after HIT_KEEP_DAYS)
// where <visitor> is a 12-character HMAC(SALT, ip + day). Nothing is read, changed and written
// back, so concurrent visits cannot overwrite each other's counts. Once a day is over, its totals are rolled up
// into visits:<day> = {views, visitors, capped} (no visitor hashes) and kept for ROLLUP_KEEP_DAYS.
// Writes are capped per day so counting cannot use up the free-plan KV write budget that anonymous reports need
// (Cloudflare free KV: 1,000 writes a day per account). The cap is global, but a data center only sees its own hits
// between listings, so it lists today's hit keys when it has no counter and again after every VISIT_RECHECK_EVERY
// hits it accepts, counting its own hits in between. Once a listing shows the cap, that is cached until UTC midnight.
// The global overshoot is therefore at most VISIT_RECHECK_EVERY x the number of data centers.
export const VISIT_WRITE_CAP = 150;
export const VISIT_RECHECK_EVERY = 50;
export const HIT_KEEP_DAYS = 8;
export const ROLLUP_KEEP_DAYS = 400;
// A finished day is rolled up only this long after its UTC midnight end, so late hits are in the listing.
export const ROLLUP_GRACE_MS = 5 * 60 * 1000;
// Visitor hashes kept in a data center's today entry. A repeat visitor found there is counted in the entry only (no KV
// write), so KV writes scale with distinct visitors, not requests.
export const VISIT_SEEN_MAX = 2000;

// Seconds until the next UTC midnight (at least 60). Today's counter entry lives that long; its freshness for the
// stats is judged by its own `at` field, not by the cache lifetime.
const secondsToMidnight = (now = Date.now()) => {
  const d = new Date(now).toISOString().slice(0, 10);
  return Math.max(60, Math.ceil((Date.parse(d) + 86400000 - now) / 1000));
};
const countEntry = (body) => new Response(JSON.stringify(body), { headers: { "Cache-Control": "max-age=" + secondsToMidnight() } });

async function dayHits(kv, day) {
  const names = [];
  let cursor;
  do {
    const page = await kv.list({ prefix: "hit:" + day + ":", cursor, limit: 1000 });
    names.push(...page.keys.map((k) => k.name));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  const seen = [...new Set(names.map((n) => n.split(":")[2]))];
  return { views: names.length, visitors: seen.length, seen, capped: names.length >= VISIT_WRITE_CAP };
}

// Today's counter entry {views, visitors, seen, capped, sinceList, at}, kept per data center (Cache API) until UTC
// midnight. `seen` holds the day's visitor hashes (the same 12 characters as in the hit keys) so visitors can be counted
// as hits arrive; it stays in the cache and is never returned to callers.
// The stats path never lists when an entry exists: it serves the running counter, which is approximate until the day's
// rollup (hits accepted by other data centers show up at the next relisting). The hit path relists after every
// VISIT_RECHECK_EVERY accepted hits (unless already capped) to re-check the global cap. Both list when there is no entry.
const countUrl = (day) => "https://visit-count.internal/v3/" + day;
async function readEntry(day) {
  const cache = globalThis.caches?.default;
  if (!cache) return null;
  const cached = await cache.match(countUrl(day)).catch(() => null);
  if (!cached) return null;
  try {
    const c = await cached.json();
    if (c && typeof c.views === "number") {
      const seen = Array.isArray(c.seen) ? c.seen : [];
      return { views: c.views, visitors: Number(c.visitors) || seen.length, seen, capped: !!c.capped, extra: Number(c.extra) || 0, sinceList: Number(c.sinceList) || 0, at: Number(c.at) || 0 };
    }
  } catch { /* fall through to a fresh listing */ }
  return null;
}
async function putEntry(day, entry) {
  const cache = globalThis.caches?.default;
  if (cache) await cache.put(countUrl(day), countEntry(entry)).catch(() => {});
}
async function todayCounts(kv, day, forHit = false) {
  const entry = await readEntry(day);
  if (entry && !(forHit && !entry.capped && entry.sinceList >= VISIT_RECHECK_EVERY)) return entry;
  const hits = await dayHits(kv, day);
  // `extra` counts views of already-recorded visitors that wrote no key; they are not in the listing, so they are carried over.
  const extra = entry?.extra || 0;
  const fresh = { views: hits.views + extra, visitors: hits.visitors, seen: hits.seen.slice(0, VISIT_SEEN_MAX), capped: hits.capped, extra, sinceList: 0, at: Date.now() };
  await putEntry(day, fresh);
  return fresh;
}

// After a visit is written, bump the running counter (views, visitors, hits since the last listing).
async function noteHit(day, entry, visitor) {
  if (!globalThis.caches?.default) return;
  const isNew = !entry.seen.includes(visitor);
  const seen = isNew && entry.seen.length < VISIT_SEEN_MAX ? [...entry.seen, visitor] : entry.seen;
  const views = entry.views + 1;
  await putEntry(day, { views, visitors: entry.visitors + (isNew ? 1 : 0), seen, extra: entry.extra, capped: views - entry.extra >= VISIT_WRITE_CAP, sinceList: entry.sinceList + 1, at: entry.at });
}

// A repeat visit from a visitor already in the entry: counted as a view in the cached entry only, no KV write, and it
// does not count toward the write cap or the relisting interval.
async function noteRepeat(day, entry) {
  await putEntry(day, { ...entry, views: entry.views + 1, extra: entry.extra + 1 });
}

async function hit(request, env) {
  const day = new Date().toISOString().slice(0, 10);
  const counts = await todayCounts(env.REPORTS, day, true);
  if (counts.capped || counts.views - counts.extra >= VISIT_WRITE_CAP) return json(request, 200, { ok: true, capped: true });
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  // The user agent is left out on purpose: it is chosen by the client, so varying it could inflate visitors.
  const visitor = (await hmac(env.SALT, "visit:" + ip + ":" + day)).slice(0, 12);
  // Without the Cache API a view could not be recorded anywhere but KV, so this shortcut needs the cache.
  if (globalThis.caches?.default && counts.seen.includes(visitor)) {
    await noteRepeat(day, counts);
    return json(request, 200, { ok: true });
  }
  await env.REPORTS.put("hit:" + day + ":" + visitor + ":" + crypto.randomUUID(), "", { expirationTtl: HIT_KEEP_DAYS * 86400 });
  await noteHit(day, counts, visitor);
  return json(request, 200, { ok: true });
}

// Rolls a finished day up into its final record (any old-format totals plus the day's per-visit keys). Zero days
// are stored too, so each past day is listed at most once. Callers only roll a day up once it is at least
// ROLLUP_GRACE_MS past its UTC midnight end; before that the day is served from the running counter.

async function rollupDay(kv, day, c) {
  const hits = await dayHits(kv, day);
  const total = { views: (c?.views || 0) + hits.views, visitors: (c?.visitors || 0) + hits.visitors, capped: !!c?.capped || hits.capped };
  await kv.put("visits:" + day, JSON.stringify(total), { expirationTtl: ROLLUP_KEEP_DAYS * 86400 });
  return total;
}

// Past days come from their rollup records (get only); a missing one is rolled up once. Today comes from the
// cached today counter, so a normal request makes no KV list calls.
export async function visitStats(env, now = new Date()) {
  const today = now.toISOString().slice(0, 10);
  const days = [];
  for (let i = 6; i >= 0; i--) days.push(new Date(now.getTime() - i * 86400000).toISOString().slice(0, 10));
  const rows = await Promise.all(days.map(async (day) => {
    const stored = await env.REPORTS.get("visits:" + day);
    const c = stored ? JSON.parse(stored) : null;
    if (day < today) {
      // A finished day's rollup is final, unless it is an old-format or in-progress record.
      if (c && !c.seen && !c.legacy) return { day, views: c.views, visitors: c.visitors, capped: !!c.capped };
      // Not before the day is ROLLUP_GRACE_MS past its end: until then it is served from the running counter below.
      if (now.getTime() >= Date.parse(day) + 86400000 + ROLLUP_GRACE_MS) return { day, ...(await rollupDay(env.REPORTS, day, c)) };
    }
    // Today is never final: a record for today can only be an old-format total, added to the per-visit counts.
    // The old record's visitor hashes are dropped the first time it is read.
    if (c?.seen) await env.REPORTS.put("visits:" + day, JSON.stringify({ views: c.views, visitors: c.visitors, capped: !!c.capped, legacy: true }), { expirationTtl: ROLLUP_KEEP_DAYS * 86400 });
    const hits = await todayCounts(env.REPORTS, day);
    return { day, views: (c?.views || 0) + hits.views, visitors: (c?.visitors || 0) + hits.visitors, capped: !!c?.capped || hits.capped };
  }));
  return { days: rows, views: rows.reduce((a, r) => a + r.views, 0), visitors: rows.reduce((a, r) => a + r.visitors, 0), capped: rows.some((r) => r.capped) };
}

const VISITS_CACHE_SECONDS = 300;

// The whole /v1/visits JSON is cached for 5 minutes per data center (Cache API), so anonymous callers cannot
// drive KV usage.
async function visits(request, env) {
  const cache = globalThis.caches?.default;
  const url = "https://visit-stats.internal/v1/visits";
  let text;
  if (cache) {
    const cached = await cache.match(url).catch(() => null);
    if (cached) text = await cached.text().catch(() => undefined);
  }
  if (text === undefined) {
    text = JSON.stringify(await visitStats(env));
    if (cache) await cache.put(url, new Response(text, { headers: { "Cache-Control": "max-age=" + VISITS_CACHE_SECONDS } })).catch(() => {});
  }
  const headers = cors(request);
  headers["Cache-Control"] = "public, max-age=" + VISITS_CACHE_SECONDS;
  return new Response(text, { status: 200, headers });
}

async function exportAll(request, env) {
  const auth = request.headers.get("Authorization") || "";
  if (!env.EXPORT_TOKEN || auth !== "Bearer " + env.EXPORT_TOKEN) return json(request, 401, { error: "unauthorized" });
  const out = [];
  let cursor;
  do {
    const page = await env.REPORTS.list({ prefix: "r:", cursor, limit: 1000 });
    for (const k of page.keys) {
      const v = await env.REPORTS.get(k.name);
      if (v) out.push(...JSON.parse(v));
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor && out.length < 50000);
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Served both as a Worker (/v1/...) and as a Pages Function under the site (/api/v1/...).
    url.pathname = url.pathname.replace(/^\/api(?=\/)/, "");
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(request) });
    if (url.pathname === "/v1/report" && request.method === "POST") return report(request, env);
    if (url.pathname === "/v1/export" && request.method === "GET") return exportAll(request, env);
    if (url.pathname === "/v1/forget" && request.method === "POST") return forget(request, env);
    if (url.pathname === "/v1/hit" && request.method === "POST") return hit(request, env);
    if (url.pathname === "/v1/visits" && request.method === "GET") return visits(request, env);
    if (url.pathname === "/" || url.pathname === "/api") return json(request, 200, { service: "AI Quota Watch collector", docs: "https://github.com/dwagwd/quotapilot/tree/main/collector" });
    return json(request, 404, { error: "not found" });
  }
};

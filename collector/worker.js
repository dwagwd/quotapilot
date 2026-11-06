// AI Quota Watch anonymous collector (Cloudflare Worker).
// POST /v1/report  {install, reports[]}  -> stores sanitized reports under an anonymous reporter id.
// GET  /v1/export  (Bearer EXPORT_TOKEN) -> every stored report, for the GitHub Action that builds the stats.
// POST /v1/forget  {install}            -> deletes every report this install sent (right to erasure).
// No IP address, GitHub account or install id is stored: the reporter id is HMAC(SALT, install id), and
// rate limits use HMAC(SALT, ip + day) counters that expire after a day.
// Each stored report also carries reporterFirstSeen (the day this reporter id was first seen; the record expires
// keepDays after that), receivedDay (the day the collector received it) and ipGroup (8 hex characters of
// HMAC(SALT, /24 or /48 network + day), so it changes every day and cannot be turned back into an address).
// The aggregation step uses them to discount brand-new reporters and reporters sharing a network on the same day.

import { sanitize, hourOf } from "./schema.js";
export { sanitize };
export const LIMITS = { bodyBytes: 20000, reports: 30, perInstallPerDay: 3, perIpPerDay: 20, newReportersPerIpPerDay: 2, keepDays: 31 };
const ALLOWED_ORIGINS = ["https://aiquotawatch.pages.dev", "https://dwagwd.github.io", "http://127.0.0.1:8765", "http://localhost:8765"];


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
  const ipKey = "rl:ip:" + (await hmac(env.SALT, "ip:" + ip + ":" + day)).slice(0, 32);
  const installKey = "rl:in:" + day + ":" + reporter;
  // A reporter is new when it has no first-seen record. Each IP address may introduce only a few new reporters a
  // day, so minting install ids cannot cheaply produce "distinct reporters". Reporters already on record are never
  // capped here, so people behind a shared address keep working. Both keys are only written when a reporter is
  // new, so ordinary submissions cost no extra KV writes.
  const seenKey = "rs:" + reporter;
  const firstSeen = await env.REPORTS.get(seenKey);
  const newKey = "rl:new:" + (await hmac(env.SALT, "ip-new:" + ip + ":" + day)).slice(0, 32);
  let introduced = 0;
  if (!firstSeen) {
    introduced = Number(await env.REPORTS.get(newKey)) || 0;
    if (introduced >= LIMITS.newReportersPerIpPerDay) return json(request, 429, { error: "too many new installs from this network today" });
  }
  if (!(await bump(env.REPORTS, ipKey, LIMITS.perIpPerDay)) || !(await bump(env.REPORTS, installKey, LIMITS.perInstallPerDay))) {
    return json(request, 429, { error: "daily limit reached" });
  }
  if (!firstSeen) {
    await env.REPORTS.put(seenKey, day, { expirationTtl: LIMITS.keepDays * 86400 });
    await env.REPORTS.put(newKey, String(introduced + 1), { expirationTtl: 2 * 86400 });
  }
  const ipGroup = (await hmac(env.SALT, "ipgrp:" + ipPrefix(ip) + ":" + day)).slice(0, 8);
  const now = hourOf(new Date().toISOString());
  const stored = reports.map((r) => ({ ...r, date: r.date || now, reporter,
    reporterFirstSeen: firstSeen || day, receivedDay: day, ipGroup }));
  // The reporter id is part of the key so /v1/forget can find this install's reports without reading them all.
  await env.REPORTS.put("r:" + day + ":" + reporter + ":" + crypto.randomUUID(), JSON.stringify(stored), { expirationTtl: LIMITS.keepDays * 86400 });
  return json(request, 200, { ok: true, accepted: stored.length });
}

// Deletes everything one install has sent: its reports (also older keys without the reporter id in the name,
// which are read to check) and its first-seen record. Only the install id itself can ask, and it never leaves the
// sender's machine except in this request; a few requests per network per day are allowed.
async function forget(request, env) {
  let body;
  try { body = JSON.parse((await request.text()).slice(0, 2000)); } catch { return json(request, 400, { error: "invalid JSON" }); }
  const install = typeof body?.install === "string" && /^[A-Za-z0-9-]{16,64}$/.test(body.install) ? body.install : null;
  if (!install) return json(request, 400, { error: "missing install id" });
  const day = new Date().toISOString().slice(0, 10);
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  if (!(await bump(env.REPORTS, "rl:forget:" + (await hmac(env.SALT, "forget:" + ip + ":" + day)).slice(0, 32), 5))) {
    return json(request, 429, { error: "daily limit reached" });
  }
  const reporter = "anon-" + (await hmac(env.SALT, "install:" + install)).slice(0, 16);
  let deleted = 0, cursor;
  do {
    const page = await env.REPORTS.list({ prefix: "r:", cursor, limit: 1000 });
    for (const k of page.keys) {
      const parts = k.name.split(":");
      let mine = parts.length === 4 ? parts[2] === reporter : false;
      if (parts.length === 3) {
        const v = await env.REPORTS.get(k.name);
        try { mine = !!v && JSON.parse(v).some((r) => r.reporter === reporter); } catch { mine = false; }
      }
      if (mine) { await env.REPORTS.delete(k.name); deleted++; }
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  await env.REPORTS.delete("rs:" + reporter);
  return json(request, 200, { ok: true, deleted });
}

// Visitor counting without cookies. Each visit is its own short-lived key,
//   hit:<day>:<visitor>:<random>   (expires after HIT_KEEP_DAYS)
// where <visitor> is a 12-character HMAC(SALT, ip + day). Nothing is read, changed and written
// back, so concurrent visits cannot overwrite each other's counts. Once a day is over, its totals are rolled up
// into visits:<day> = {views, visitors, capped} (no visitor hashes) and kept for ROLLUP_KEEP_DAYS.
// Writes are capped per day so counting cannot use up the free-plan KV write budget that anonymous reports need
// (Cloudflare free KV: 1,000 writes a day per account). The cap is checked against a key listing that may be up to
// COUNT_CACHE_SECONDS old, so it can be exceeded by the visits that arrive within that window.
export const VISIT_WRITE_CAP = 500;
export const HIT_KEEP_DAYS = 8;
export const ROLLUP_KEEP_DAYS = 400;
const COUNT_CACHE_SECONDS = 60;

async function dayHits(kv, day) {
  const names = [];
  let cursor;
  do {
    const page = await kv.list({ prefix: "hit:" + day + ":", cursor, limit: 1000 });
    names.push(...page.keys.map((k) => k.name));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return { views: names.length, visitors: new Set(names.map((n) => n.split(":")[2])).size, capped: names.length >= VISIT_WRITE_CAP };
}

// Today's view count for the cap, cached briefly per data center (Cache API) to keep KV list operations low.
async function todayViews(kv, day) {
  const cache = globalThis.caches?.default;
  const url = "https://visit-count.internal/" + day;
  if (cache) {
    const cached = await cache.match(url).catch(() => null);
    if (cached) return Number(await cached.text()) || 0;
  }
  const { views } = await dayHits(kv, day);
  if (cache) await cache.put(url, new Response(String(views), { headers: { "Cache-Control": "max-age=" + COUNT_CACHE_SECONDS } })).catch(() => {});
  return views;
}

async function hit(request, env) {
  const day = new Date().toISOString().slice(0, 10);
  if ((await todayViews(env.REPORTS, day)) >= VISIT_WRITE_CAP) return json(request, 200, { ok: true, capped: true });
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  // The user agent is left out on purpose: it is chosen by the client, so varying it could inflate visitors.
  const visitor = (await hmac(env.SALT, "visit:" + ip + ":" + day)).slice(0, 12);
  await env.REPORTS.put("hit:" + day + ":" + visitor + ":" + crypto.randomUUID(), "", { expirationTtl: HIT_KEEP_DAYS * 86400 });
  return json(request, 200, { ok: true });
}

export async function visitStats(env, now = new Date()) {
  const today = now.toISOString().slice(0, 10);
  const days = [];
  for (let i = 6; i >= 0; i--) days.push(new Date(now.getTime() - i * 86400000).toISOString().slice(0, 10));
  const rows = await Promise.all(days.map(async (day) => {
    const stored = await env.REPORTS.get("visits:" + day);
    const c = stored ? JSON.parse(stored) : null;
    // A finished day's rollup is final. Today is never final: a record for today can only be an old-format total.
    if (c && !c.seen && !c.legacy && day < today) return { day, views: c.views, visitors: c.visitors, capped: !!c.capped };
    // Days counted partly by the old single-record format: add the old totals to the per-visit keys.
    // The old record's visitor hashes are dropped the first time it is read.
    if (c?.seen) await env.REPORTS.put("visits:" + day, JSON.stringify({ views: c.views, visitors: c.visitors, capped: !!c.capped, legacy: true }), { expirationTtl: ROLLUP_KEEP_DAYS * 86400 });
    const hits = await dayHits(env.REPORTS, day);
    const total = { views: (c?.views || 0) + hits.views, visitors: (c?.visitors || 0) + hits.visitors, capped: !!c?.capped || hits.capped };
    if (day < today && total.views > 0) await env.REPORTS.put("visits:" + day, JSON.stringify(total), { expirationTtl: ROLLUP_KEEP_DAYS * 86400 });
    return { day, ...total };
  }));
  return { days: rows, views: rows.reduce((a, r) => a + r.views, 0), visitors: rows.reduce((a, r) => a + r.visitors, 0), capped: rows.some((r) => r.capped) };
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
    if (url.pathname === "/v1/visits" && request.method === "GET") {
      const res = json(request, 200, await visitStats(env));
      res.headers.set("Cache-Control", "public, max-age=300");
      return res;
    }
    if (url.pathname === "/" || url.pathname === "/api") return json(request, 200, { service: "AI Quota Watch collector", docs: "https://github.com/dwagwd/quotapilot/tree/main/collector" });
    return json(request, 404, { error: "not found" });
  }
};

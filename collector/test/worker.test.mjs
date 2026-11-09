import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { sanitize, ipPrefix, LIMITS, LEGACY_KEYS_UNTIL, visitStats, VISIT_WRITE_CAP, VISIT_RECHECK_EVERY, HIT_KEEP_DAYS, ROLLUP_KEEP_DAYS } from "../worker.js";

function kv() {
  const m = new Map();
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    ttl: new Map(),
    async put(k, v, o) { await new Promise((r) => setTimeout(r, 1)); m.set(k, v); this.ttl.set(k, o?.expirationTtl); },
    async delete(k) { m.delete(k); },
    async list({ prefix, cursor, limit = 1000 }) {
      const all = [...m.keys()].filter((k) => k.startsWith(prefix)).sort().filter((k) => !cursor || k > cursor);
      const keys = all.slice(0, limit).map((name) => ({ name }));
      const complete = all.length <= limit;
      return { keys, list_complete: complete, cursor: complete ? undefined : keys[keys.length - 1].name };
    }
  };
}
const env = () => ({ REPORTS: kv(), SALT: "test-salt", EXPORT_TOKEN: "secret-token" });
const post = (body, ip = "1.2.3.4", origin) => new Request("https://c.example/v1/report", {
  method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
  headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip, ...(origin ? { Origin: origin } : {}) }
});
const install = "0f8d6c2a-1111-4222-8333-944455556666";
const good = { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, calls: 3, effort: "high" };

test("stores sanitized reports under an anonymous id, never the install id or IP", async () => {
  const e = env();
  const res = await worker.fetch(post({ install, reports: [good, { type: "quota", plan: "<b>Plus</b>", extra: "x" }, { type: "nope" }] }), e);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).accepted, 2);
  const stored = [...e.REPORTS.m.entries()].filter(([k]) => k.startsWith("r:"));
  assert.equal(stored.length, 1);
  const text = stored[0][1];
  assert.ok(!text.includes(install) && !text.includes("1.2.3.4"));
  const rows = JSON.parse(text);
  assert.match(rows[0].reporter, /^anon-[0-9a-f]{16}$/);
  assert.equal(rows[1].plan, undefined, "a plan name with markup is not stored at all");
  assert.equal(rows[1].extra, undefined);
});

test("the same install keeps the same anonymous id", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  await worker.fetch(post({ install, reports: [good] }, "5.6.7.8"), e);
  const ids = [...e.REPORTS.m.entries()].filter(([k]) => k.startsWith("r:")).map(([, v]) => JSON.parse(v)[0].reporter);
  assert.equal(new Set(ids).size, 1);
});

test("rejects bad input and enforces daily limits", async () => {
  const e = env();
  assert.equal((await worker.fetch(post("{not json"), e)).status, 400);
  assert.equal((await worker.fetch(post({ install: "short", reports: [good] }), e)).status, 400);
  assert.equal((await worker.fetch(post({ install, reports: [{ type: "x" }] }), e)).status, 400);
  assert.equal((await worker.fetch(post("x".repeat(LIMITS.bodyBytes + 1)), e)).status, 413);
  const codes = [];
  for (let i = 0; i < LIMITS.perInstallPerDay + 1; i++) codes.push((await worker.fetch(post({ install, reports: [good] }), e)).status);
  assert.deepEqual(codes.slice(-1), [429]);
});

const installN = (n) => "aaaaaaaa-0000-4000-8000-" + String(n).padStart(12, "0");
const storedRows = (e) => [...e.REPORTS.m.entries()].filter(([k]) => k.startsWith("r:")).flatMap(([, v]) => JSON.parse(v));

test("one IP can introduce only a few new reporters a day; known reporters are still accepted", async () => {
  const e = env();
  const codes = [];
  for (let i = 1; i <= LIMITS.newReportersPerIpPerDay + 1; i++) codes.push((await worker.fetch(post({ install: installN(i), reports: [good] }, "1.2.3.4"), e)).status);
  assert.deepEqual(codes, [...Array(LIMITS.newReportersPerIpPerDay).fill(200), 429]);
  // A reporter this IP already introduced, and one first seen elsewhere, are both still accepted from it.
  assert.equal((await worker.fetch(post({ install: installN(1), reports: [good] }, "1.2.3.4"), e)).status, 200);
  assert.equal((await worker.fetch(post({ install: installN(9), reports: [good] }, "5.5.5.5"), e)).status, 200);
  assert.equal((await worker.fetch(post({ install: installN(9), reports: [good] }, "1.2.3.4"), e)).status, 200);
  // Another IP can still introduce new reporters.
  assert.equal((await worker.fetch(post({ install: installN(3), reports: [good] }, "6.6.6.6"), e)).status, 200);
  // Only hashed, short-lived keys: no IP in any key or value, and the new-reporter counter expires within 2 days.
  const dump = [...e.REPORTS.m.keys()].join(" ") + [...e.REPORTS.m.values()].join(" ");
  assert.ok(!dump.includes("1.2.3.4") && !dump.includes("5.5.5.5"));
  const newKeys = [...e.REPORTS.ttl.entries()].filter(([k]) => k.startsWith("rl:new:"));
  assert.ok(newKeys.length >= 2 && newKeys.every(([k, t]) => /^rl:new:[0-9a-f]{32}$/.test(k) && t <= 2 * 86400));
});

test("known reporters cost no extra KV writes", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  let writes = 0; const put = e.REPORTS.put.bind(e.REPORTS); e.REPORTS.put = async (k, v, o) => { writes++; return put(k, v, o); };
  await worker.fetch(post({ install, reports: [good] }), e);
  assert.equal(writes, 3); // global day counter, install counter, the report itself (no network counter)
});

test("KV writes per accepted batch fit the free-plan budget", async () => {
  const e = env();
  let writes = 0; const put = e.REPORTS.put.bind(e.REPORTS); e.REPORTS.put = async (k, v, o) => { writes++; return put(k, v, o); };
  await worker.fetch(post({ install, reports: [good] }), e);
  assert.equal(writes, 6); // day, install, network, first-seen, new-reporter counter, the report
  writes = 0;
  await worker.fetch(post({ install, reports: [good] }, "5.6.7.8"), e);
  assert.equal(writes, 3);
  assert.equal([...e.REPORTS.m.keys()].filter((k) => k.startsWith("rl:ip:")).length, 1, "a known reporter does not write a network counter");
  // Worst case per class: known batch 3 writes, new batch 6, forget 96 (2 counters + 94 deletes), plus the visit cap and slack.
  assert.ok(LIMITS.knownBatchesPerDay * 3 + LIMITS.newBatchesPerDay * 6 + LIMITS.forgetsPerDay * 96 + VISIT_WRITE_CAP + LIMITS.slackWrites <= 1000);
});

test("reports carry a stable reporterFirstSeen and an ipGroup that does not contain the IP", async () => {
  const e = env();
  const today = new Date().toISOString().slice(0, 10);
  await worker.fetch(post({ install, reports: [good] }, "203.0.113.7"), e);
  // A later submission keeps the first-seen day even if the record says it was first seen earlier.
  e.REPORTS.m.set([...e.REPORTS.m.keys()].find((k) => k.startsWith("rs:")), "2000-01-01");
  await worker.fetch(post({ install, reports: [{ ...good, reporterFirstSeen: "1999-01-01", ipGroup: "deadbeef" }] }, "203.0.113.99"), e);
  const rows = storedRows(e).sort((a, b) => (a.reporterFirstSeen < b.reporterFirstSeen ? 1 : -1));
  assert.equal(rows[0].reporterFirstSeen, today);
  assert.equal(rows[1].reporterFirstSeen, "2000-01-01", "the stored first-seen day wins; client-sent values are ignored");
  assert.ok(rows.every((r) => r.receivedDay === today));
  assert.ok(rows.every((r) => /^[0-9a-f]{8}$/.test(r.ipGroup)));
  assert.equal(rows[0].ipGroup, rows[1].ipGroup, "same /24 on the same day shares a group");
  await worker.fetch(post({ install: installN(5), reports: [good] }, "198.51.100.7"), e);
  assert.notEqual(storedRows(e).find((r) => r.reporter !== rows[0].reporter).ipGroup, rows[0].ipGroup);
  const text = [...e.REPORTS.m.values()].join(" ");
  assert.ok(!text.includes("203.0.113") && !text.includes("198.51.100"));
  assert.equal(e.REPORTS.ttl.get([...e.REPORTS.m.keys()].find((k) => k.startsWith("rs:"))), LIMITS.keepDays * 86400);
});

test("ipPrefix uses /24 for IPv4 and /48 for IPv6", () => {
  assert.equal(ipPrefix("203.0.113.7"), ipPrefix("203.0.113.250"));
  assert.notEqual(ipPrefix("203.0.113.7"), ipPrefix("203.0.114.7"));
  assert.equal(ipPrefix("::ffff:203.0.113.7"), ipPrefix("203.0.113.9"));
  assert.equal(ipPrefix("2001:db8:abcd:1::1"), ipPrefix("2001:0db8:abcd:ffff:1:2:3:4"));
  assert.equal(ipPrefix("2001:db8::1"), "v6:2001:db8:0");
  assert.notEqual(ipPrefix("2001:db8:abcd::1"), ipPrefix("2001:db8:abce::1"));
});

test("export needs the token and returns everything", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good, good] }), e);
  assert.equal((await worker.fetch(new Request("https://c.example/v1/export"), e)).status, 401);
  const res = await worker.fetch(new Request("https://c.example/v1/export", { headers: { Authorization: "Bearer secret-token" } }), e);
  assert.equal((await res.json()).length, 2);
});

test("CORS only for the site", async () => {
  const e = env();
  const ok = await worker.fetch(post({ install, reports: [good] }, "9.9.9.9", "https://dwagwd.github.io"), e);
  assert.equal(ok.headers.get("Access-Control-Allow-Origin"), "https://dwagwd.github.io");
  const other = await worker.fetch(post({ install, reports: [good] }, "9.9.9.8", "https://evil.example"), e);
  assert.equal(other.headers.get("Access-Control-Allow-Origin"), null);
  assert.equal(sanitize({ type: "speed", seconds: Infinity }).seconds, undefined);
});

test("works under /api when served as a Pages Function", async () => {
  const e = env();
  const req = new Request("https://aiquotawatch.pages.dev/api/v1/report", { method: "POST", body: JSON.stringify({ install, reports: [good] }), headers: { "CF-Connecting-IP": "7.7.7.7" } });
  assert.equal((await worker.fetch(req, e)).status, 200);
});

test("counts views and unique visitors for 7 days without storing who visited", async () => {
  const e = env();
  const hitFrom = (ip, ua) => worker.fetch(new Request("https://aiquotawatch.pages.dev/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": ip, "User-Agent": ua } }), e);
  await hitFrom("1.1.1.1", "A"); await hitFrom("1.1.1.1", "A"); await hitFrom("2.2.2.2", "B");
  const stats = await visitStats(e);
  assert.equal(stats.views, 3);
  assert.equal(stats.visitors, 2);
  assert.equal(stats.days.length, 7);
  const stored = [...e.REPORTS.m.keys()].join(" ") + [...e.REPORTS.m.values()].join(" ");
  assert.ok(!stored.includes("1.1.1.1") && !stored.includes("2.2.2.2"));
  const res = await worker.fetch(new Request("https://aiquotawatch.pages.dev/api/v1/visits"), e);
  assert.equal((await res.json()).views, 3);
});

test("changing only the user agent does not add visitors", async () => {
  const e = env();
  for (const ua of ["A", "B", "curl/8", "Mozilla/5.0 x"]) await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "1.1.1.1", "User-Agent": ua } }), e);
  const stats = await visitStats(e);
  assert.equal(stats.views, 4);
  assert.equal(stats.visitors, 1);
});

test("visit counting stops writing at the daily cap", async () => {
  const e = env();
  let writes = 0; const put = e.REPORTS.put.bind(e.REPORTS); e.REPORTS.put = async (k, v, o) => { writes++; return put(k, v, o); };
  for (let i = 0; i < VISIT_WRITE_CAP + 20; i++) await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "10.0.0." + (i % 250) } }), e);
  assert.equal(writes, VISIT_WRITE_CAP);
  const stats = await visitStats(e);
  assert.equal(stats.capped, true);
  assert.equal(stats.views, VISIT_WRITE_CAP);
});

test("concurrent visits are all counted", async () => {
  const e = env();
  await Promise.all([1, 2, 3, 4, 5].map((i) => worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "3.3.3." + i } }), e)));
  const stats = await visitStats(e);
  assert.equal(stats.views, 5);
  assert.equal(stats.visitors, 5);
});

test("visitor hashes expire within days; only totals are kept long term", async () => {
  const e = env();
  await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "4.4.4.4" } }), e);
  const hitKeys = [...e.REPORTS.ttl.entries()].filter(([k]) => k.startsWith("hit:"));
  assert.equal(hitKeys.length, 1);
  assert.equal(hitKeys[0][1], HIT_KEEP_DAYS * 86400);
  // Ten minutes after the day ends, the finished day is rolled up without hashes.
  const day = new Date().toISOString().slice(0, 10);
  const tomorrow = new Date(Date.parse(day) + 86400000 + 600000);
  const stats = await visitStats(e, tomorrow);
  assert.equal(stats.views, 1);
  const rollup = JSON.parse(e.REPORTS.m.get("visits:" + day));
  assert.deepEqual(rollup, { views: 1, visitors: 1, capped: false });
  assert.equal(e.REPORTS.ttl.get("visits:" + day), ROLLUP_KEEP_DAYS * 86400);
});

test("old daily records lose their visitor hashes when read", async () => {
  const e = env();
  const day = new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10);
  e.REPORTS.m.set("visits:" + day, JSON.stringify({ views: 4, visitors: 2, seen: ["aaaaaaaaaaaa", "bbbbbbbbbbbb"] }));
  const stats = await visitStats(e);
  assert.equal(stats.views, 4);
  assert.equal(JSON.parse(e.REPORTS.m.get("visits:" + day)).seen, undefined);
});

test("today's old-format record is combined with new per-visit keys", async () => {
  const e = env();
  const today = new Date().toISOString().slice(0, 10);
  e.REPORTS.m.set("visits:" + today, JSON.stringify({ views: 2, visitors: 2, seen: ["aaaaaaaaaaaa", "bbbbbbbbbbbb"] }));
  await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "6.6.6.6" } }), e);
  let stats = await visitStats(e);
  assert.equal(stats.views, 3);
  assert.equal(JSON.parse(e.REPORTS.m.get("visits:" + today)).seen, undefined);
  await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "6.6.6.7" } }), e);
  stats = await visitStats(e);
  assert.equal(stats.views, 4);
  assert.equal(stats.visitors, 4);
  // After the day ends it rolls up into one final record.
  stats = await visitStats(e, new Date(Date.parse(today) + 86400000 + 600000));
  assert.deepEqual(JSON.parse(e.REPORTS.m.get("visits:" + today)), { views: 4, visitors: 4, capped: false });
});

test("a hash-free total stored for today is still combined with today's visits", async () => {
  const e = env();
  const today = new Date().toISOString().slice(0, 10);
  e.REPORTS.m.set("visits:" + today, JSON.stringify({ views: 2, visitors: 2, capped: false }));
  await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "8.8.8.8" } }), e);
  assert.equal((await visitStats(e)).views, 3);
});

test("prompt and cache token totals are kept, other extras are dropped", () => {
  const r = sanitize({ type: "speed", model: "claude-opus-5-5", outputTokens: 1000, inputTokens: 12, cacheReadTokens: 50000, cacheWriteTokens: 800, prompt: "secret" });
  assert.equal(r.inputTokens, 12);
  assert.equal(r.cacheReadTokens, 50000);
  assert.equal(r.cacheWriteTokens, 800);
  assert.equal(r.prompt, undefined);
});

test("forget deletes every report from one install and nothing else", async () => {
  const e = env();
  const other = "9a8b7c6d-1111-4222-8333-944455556666";
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 200);
  assert.equal((await worker.fetch(post({ install: other, reports: [good] }, "5.6.7.8"), e)).status, 200);
  const keys = () => [...e.REPORTS.m.keys()].filter((k) => k.startsWith("r:"));
  const reporterOf = (k) => JSON.parse(e.REPORTS.m.get(k))[0].reporter;
  const mine = reporterOf(keys()[0]); // the first install's reports were stored first
  // an older-format key (no reporter id in its name) holding this install's reports
  e.REPORTS.m.set("r:2026-11-01:legacy", e.REPORTS.m.get(keys().find((k) => reporterOf(k) === mine)));
  const forget = (body) => new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify(body), headers: { "CF-Connecting-IP": "1.2.3.4" } });
  const res = await worker.fetch(forget({ install }), e);
  assert.equal(res.status, 200);
  const left = keys().map(reporterOf);
  assert.equal(left.length, 1, "only the other install's report remains");
  assert.equal((await res.json()).deleted, 2);
  assert.equal(e.REPORTS.m.has("rs:" + mine), false);
  assert.equal((await worker.fetch(forget({ install: "bad" }), e)).status, 400);
});

test("only fields the stats use are kept, with known values, ranges and hour-precision times", () => {
  const r = sanitize({ type: "speed", model: "claude-opus-5-5", client: "My laptop at ACME", effort: "turbo", task: "secret project",
    plan: "Max 5x", via: "quotapilot", outputTokens: -1, seconds: 12.5, calls: 3, date: "2026-11-06T10:42:13.123Z", prompt: "hello", email: "a@b.c" });
  assert.equal(r.model, "claude-opus-5-5");
  assert.equal(r.plan, "Max 5x");
  for (const k of ["client", "effort", "task", "outputTokens", "prompt", "email"]) assert.equal(r[k], undefined, k);
  assert.equal(r.date, "2026-11-06T10:00:00Z");
  assert.equal(sanitize({ type: "speed", model: "Bob Smith <bob@example.com>" }).model, undefined);
});

test("reports dated in the future or more than 8 days back are refused", async () => {
  const e = env();
  const old = { ...good, date: new Date(Date.now() - 20 * 864e5).toISOString() };
  const future = { ...good, date: new Date(Date.now() + 3 * 864e5).toISOString() };
  const res = await worker.fetch(post({ install, reports: [old, future, good] }), e);
  assert.equal((await res.json()).accepted, 1);
});

test("event reports may carry resetAt, cut to the hour", () => {
  assert.equal(sanitize({ type: "event", kind: "reset", resetAt: "2026-11-06T10:42:13.123Z" }).resetAt, "2026-11-06T10:00:00Z");
  assert.equal(sanitize({ type: "event", resetAt: "not a date" }).resetAt, undefined);
  assert.equal(sanitize({ type: "event", resetAt: 12345 }).resetAt, undefined);
});

test("reports are stored under r:<reporter>:<day>:<uuid>", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  const key = [...e.REPORTS.m.keys()].find((k) => k.startsWith("r:"));
  assert.match(key, /^r:anon-[0-9a-f]{16}:\d{4}-\d{2}-\d{2}:[0-9a-f-]{36}$/);
});

test("forget lists by reporter prefix plus a bounded scan of old date-prefixed keys", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  await worker.fetch(post({ install: installN(7), reports: [good] }, "5.6.7.8"), e);
  const keys = () => [...e.REPORTS.m.keys()].filter((k) => k.startsWith("r:"));
  const mineKey = keys()[0];
  const reporter = mineKey.split(":")[1];
  e.REPORTS.m.set("r:2026-11-01:" + reporter + ":old-uuid", "[]");
  e.REPORTS.m.set("r:2026-11-01:anon-0000000000000000:other-uuid", "[]");
  const prefixes = [];
  const list = e.REPORTS.list.bind(e.REPORTS);
  e.REPORTS.list = async (o) => { prefixes.push(o.prefix); return list(o); };
  const res = await worker.fetch(new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install }), headers: { "CF-Connecting-IP": "1.2.3.4" } }), e);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).deleted, 2);
  assert.deepEqual(prefixes, ["r:" + reporter + ":", "r:20"]);
  assert.equal(keys().length, 2, "the other reporter's new key and the other old-format key remain");
  assert.ok(!keys().some((k) => k.includes(reporter)));
});

test("forget removes old-format keys beyond the first 1,000", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  const reporter = [...e.REPORTS.m.keys()].find((k) => k.startsWith("r:")).split(":")[1];
  for (let i = 0; i < 1100; i++) e.REPORTS.m.set("r:2026-10-01:anon-0000000000000000:u" + i, "[]");
  for (let i = 0; i < 3; i++) e.REPORTS.m.set("r:2026-11-02:" + reporter + ":u" + i, "[]");
  let oldLists = 0;
  const list = e.REPORTS.list.bind(e.REPORTS);
  e.REPORTS.list = async (o) => { if (o.prefix === "r:20") oldLists++; return list(o); };
  const res = await worker.fetch(new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install }), headers: { "CF-Connecting-IP": "1.2.3.4" } }), e);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).deleted, 4);
  assert.ok(oldLists >= 2, "walked past the first page");
  const left = [...e.REPORTS.m.keys()].filter((k) => k.startsWith("r:"));
  assert.ok(!left.some((k) => k.includes(reporter)));
  assert.equal(left.length, 1100);
});

test("once the cap is reached the hit path stops listing and caches that until UTC midnight", async () => {
  const store = new Map(); const cacheControl = [];
  globalThis.caches = { default: {
    async match(u) { const r = store.get(u); return r ? r.clone() : undefined; },
    async put(u, r) { cacheControl.push(r.headers.get("Cache-Control")); store.set(u, r); }
  } };
  const realNow = Date.now; let offset = 0;
  Date.now = () => realNow() + offset;
  try {
    const e = env();
    let lists = 0;
    const list = e.REPORTS.list.bind(e.REPORTS);
    e.REPORTS.list = async (o) => { lists++; return list(o); };
    const hit = (i) => worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "10.0." + Math.floor(i / 250) + "." + (i % 250) } }), e);
    for (let i = 0; i < VISIT_WRITE_CAP; i++) { await hit(i); if (i === 10 || i === 300) offset += 61000; }
    assert.equal(lists, VISIT_WRITE_CAP / VISIT_RECHECK_EVERY, "listed when there was no counter and again after every 50 accepted hits");
    const listsAtCap = lists;
    const now = Date.now();
    const expected = Math.max(60, Math.ceil((Date.parse(new Date(now).toISOString().slice(0, 10)) + 86400000 - now) / 1000));
    assert.ok(Math.abs(Number(cacheControl.at(-1).match(/max-age=(\d+)/)[1]) - expected) <= 5, "capped state is cached until UTC midnight");
    offset += 61000;
    for (let i = 0; i < 20; i++) assert.equal((await (await hit(VISIT_WRITE_CAP + i)).json()).capped, true);
    assert.equal(lists, listsAtCap, "no further listing once the cap is known");
    assert.equal([...e.REPORTS.m.keys()].filter((k) => k.startsWith("hit:")).length, VISIT_WRITE_CAP);
  } finally {
    Date.now = realNow;
    delete globalThis.caches;
  }
});

test("a looping install is stopped by its own limit before it uses the network's budget", async () => {
  const e = env();
  for (let i = 0; i < LIMITS.perInstallPerDay + 3; i++) await worker.fetch(post({ install, reports: [good] }), e);
  const ipKeys = [...e.REPORTS.m.entries()].filter(([k]) => k.startsWith("rl:ip:"));
  assert.equal(ipKeys.length, 1);
  assert.equal(ipKeys[0][1], "1", "only the first (new-reporter) batch touched the network counter");
});

test("IPv6 addresses in one /48 share the network limits", async () => {
  const e = env();
  const addrs = ["2001:db8:abcd:1::1", "2001:db8:abcd:2::2", "2001:db8:abcd:ffff:1:2:3:4"];
  const codes = [];
  for (let i = 0; i < addrs.length; i++) codes.push((await worker.fetch(post({ install: installN(i + 1), reports: [good] }, addrs[i]), e)).status);
  assert.deepEqual(codes, [200, 200, 429]);
  assert.equal((await worker.fetch(post({ install: installN(4), reports: [good] }, "2001:db8:abce::1"), e)).status, 200);
  const dump = [...e.REPORTS.m.keys()].join(" ") + [...e.REPORTS.m.values()].join(" ");
  assert.ok(!dump.includes("2001:db8"));
});

test("each reporter class has its own daily cap, refused with 429 {full:true} before writing anything", async () => {
  const e = env();
  const day = new Date().toISOString().slice(0, 10);
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 200);
  assert.equal(e.REPORTS.m.get("rl:day:new:" + day), "1");
  // New class full: another new reporter is refused, nothing written.
  e.REPORTS.m.set("rl:day:new:" + day, String(LIMITS.newBatchesPerDay));
  let before = [...e.REPORTS.m.keys()];
  let res = await worker.fetch(post({ install: installN(2), reports: [good] }, "5.5.5.5"), e);
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "collector is full for today", full: true });
  assert.deepEqual([...e.REPORTS.m.keys()], before);
  // ...but a reporter on record still gets in, through the known counter.
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 200);
  assert.equal(e.REPORTS.m.get("rl:day:known:" + day), "1");
  // Known class full.
  e.REPORTS.m.set("rl:day:known:" + day, String(LIMITS.knownBatchesPerDay));
  before = [...e.REPORTS.m.keys()];
  res = await worker.fetch(post({ install, reports: [good] }), e);
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "collector is full for today", full: true });
  assert.deepEqual([...e.REPORTS.m.keys()], before);
  e.REPORTS.m.set("rl:day:known:" + day, String(LIMITS.knownBatchesPerDay - 1));
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 200);
  assert.equal(e.REPORTS.m.get("rl:day:known:" + day), String(LIMITS.knownBatchesPerDay));
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 429);
});

const siteEnv = () => ({ ...env(), TURNSTILE_SECRET: "ts-secret" });
// Runs fn with a mocked global fetch standing in for Turnstile's siteverify; `reply` is a body or a function that throws.
async function withSiteverify(reply, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), method: init?.method, form: new URLSearchParams(String(init?.body)) });
    if (typeof reply === "function") return reply();
    return new Response(JSON.stringify(reply));
  };
  try { await fn(calls); } finally { globalThis.fetch = real; }
}
const siteOrigin = "https://aiquotawatch.pages.dev";

test("a valid Turnstile token makes the report via site, and the token is never stored", async () => {
  await withSiteverify({ success: true, hostname: "aiquotawatch.pages.dev" }, async (calls) => {
    const e = siteEnv();
    const res = await worker.fetch(post({ install, turnstile: "tok-1", reports: [{ ...good, via: "quotapilot" }] }, "1.2.3.4", siteOrigin), e);
    assert.equal(res.status, 200);
    assert.equal(storedRows(e)[0].via, "site");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].form.get("secret"), "ts-secret");
    assert.equal(calls[0].form.get("response"), "tok-1");
    assert.equal(calls[0].form.get("remoteip"), "1.2.3.4");
    assert.ok(![...e.REPORTS.m.keys()].join(" ").includes("tok-1") && ![...e.REPORTS.m.values()].join(" ").includes("tok-1"));
    // A body that claims via site without an Origin is checked too, and labelled site once the token verifies.
    const e2 = siteEnv();
    assert.equal((await worker.fetch(post({ install, turnstile: "tok-2", reports: [{ ...good, via: "site" }] }), e2)).status, 200);
    assert.equal(storedRows(e2)[0].via, "site");
    assert.equal(calls.length, 2);
  });
});

test("a failed, wrong-host, missing or unreachable Turnstile check is refused with 403 and nothing is written", async () => {
  const refused = async (reply, body, expectCalls) => {
    await withSiteverify(reply, async (calls) => {
      const e = siteEnv();
      const res = await worker.fetch(post(body, "1.2.3.4", siteOrigin), e);
      assert.equal(res.status, 403);
      assert.deepEqual(await res.json(), { error: "verification failed" });
      assert.equal(e.REPORTS.m.size, 0, "no report and no counter written");
      assert.equal(calls.length, expectCalls);
    });
  };
  const reports = [{ ...good, via: "site" }];
  await refused({ success: false, "error-codes": ["invalid-input-response"] }, { install, turnstile: "bad", reports }, 1);
  await refused({ success: true, hostname: "evil.example" }, { install, turnstile: "other-host", reports }, 1);
  await refused({ success: true, hostname: "aiquotawatch.pages.dev" }, { install, reports }, 0);
  await refused(() => { throw new Error("network down"); }, { install, turnstile: "x", reports }, 1);
});

test("without TURNSTILE_SECRET nothing is labelled site, and siteverify is never called", async () => {
  await withSiteverify({ success: true, hostname: "aiquotawatch.pages.dev" }, async (calls) => {
    const e = env();
    assert.equal((await worker.fetch(post({ install, turnstile: "tok", reports: [{ ...good, via: "site" }] }, "1.2.3.4", siteOrigin), e)).status, 200);
    assert.equal(storedRows(e)[0].via, "quotapilot");
    assert.equal(calls.length, 0);
  });
});

test("QuotaPilot app requests never call siteverify and keep their via, with or without a secret", async () => {
  await withSiteverify({ success: true, hostname: "aiquotawatch.pages.dev" }, async (calls) => {
    for (const e of [siteEnv(), env()]) {
      assert.equal((await worker.fetch(post({ install, reports: [{ ...good, via: "quotapilot" }] }), e)).status, 200);
      assert.equal(storedRows(e)[0].via, "quotapilot");
    }
    assert.equal(calls.length, 0);
  });
});

test("visits are served from rollups and the cached today counter without KV list calls", async () => {
  const store = new Map();
  globalThis.caches = { default: {
    async match(u) { const r = store.get(u); return r ? r.clone() : undefined; },
    async put(u, r) { store.set(u, r); }
  } };
  try {
    const e = env();
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    e.REPORTS.m.set("hit:" + yesterday + ":aaaaaaaaaaaa:u1", "");
    e.REPORTS.m.set("hit:" + yesterday + ":bbbbbbbbbbbb:u2", "");
    // A visit today primes the cached today counter.
    await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "9.9.9.9" } }), e);
    // The first call rolls the finished days up once.
    const first = await visitStats(e);
    assert.equal(first.views, 3);
    assert.equal(first.visitors, 3);
    assert.deepEqual(JSON.parse(e.REPORTS.m.get("visits:" + yesterday)), { views: 2, visitors: 2, capped: false });
    let lists = 0;
    const list = e.REPORTS.list.bind(e.REPORTS);
    e.REPORTS.list = async (o) => { lists++; return list(o); };
    const again = await visitStats(e);
    assert.equal(again.views, 3);
    assert.equal(lists, 0);
    const res = await worker.fetch(new Request("https://x/api/v1/visits"), e);
    const body = await res.json();
    assert.equal(body.views, 3);
    assert.equal(body.days.length, 7);
    assert.equal(res.headers.get("Cache-Control"), "public, max-age=300");
    assert.equal(lists, 0);
    // The whole response is cached: a later hit does not change it within the window.
    e.REPORTS.m.set("visits:" + yesterday, JSON.stringify({ views: 50, visitors: 50, capped: false }));
    assert.equal((await (await worker.fetch(new Request("https://x/api/v1/visits"), e)).json()).views, 3);
  } finally {
    delete globalThis.caches;
  }
});

function fakeCache() {
  const store = new Map();
  globalThis.caches = { default: {
    async match(u) { const r = store.get(u); return r ? r.clone() : undefined; },
    async put(u, r) { store.set(u, r); }
  } };
  return store;
}

test("the hit path re-lists today's keys every 50 accepted hits, so the global overshoot stays bounded", async () => {
  fakeCache();
  try {
    const e = env();
    const today = new Date().toISOString().slice(0, 10);
    let lists = 0;
    const list = e.REPORTS.list.bind(e.REPORTS);
    e.REPORTS.list = async (o) => { lists++; return list(o); };
    // Distinct visitors: repeat visitors are counted in the cache only and do not count as accepted (written) hits.
    const hit = (n) => worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "20.0.0." + n } }), e);
    await hit(0);
    // Other data centers fill the day up to the cap while this one only counts its own hits.
    for (let i = 0; i < VISIT_WRITE_CAP; i++) e.REPORTS.m.set("hit:" + today + ":zzzzzzzzzzzz:o" + i, "");
    for (let i = 1; i < VISIT_RECHECK_EVERY; i++) await hit(i);
    assert.equal(lists, 1, "no relisting before 50 accepted hits");
    const res = await hit(VISIT_RECHECK_EVERY);
    assert.equal((await res.json()).capped, true);
    assert.equal(lists, 2, "relisted after 50 accepted hits");
    const hitKeys = [...e.REPORTS.m.keys()].filter((k) => k.startsWith("hit:")).length;
    assert.equal(hitKeys, VISIT_WRITE_CAP + VISIT_RECHECK_EVERY, "overshoot is at most 50 for this data center");
  } finally {
    delete globalThis.caches;
  }
});

test("the stats path never lists today when an entry exists, and lists once when there is none", async () => {
  const store = fakeCache();
  try {
    const e = env();
    const today = new Date().toISOString().slice(0, 10);
    await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "9.9.9.9" } }), e);
    for (let i = 0; i < 5; i++) e.REPORTS.m.set("hit:" + today + ":cccccccccccc:o" + i, "");
    let todayLists = 0;
    const list = e.REPORTS.list.bind(e.REPORTS);
    e.REPORTS.list = async (o) => { if (o.prefix === "hit:" + today + ":") todayLists++; return list(o); };
    let stats = await visitStats(e);
    assert.equal(todayLists, 0);
    assert.equal(stats.views, 1, "served from the running counter, approximate until the rollup");
    assert.equal(stats.visitors, 1);
    // With no entry at all, today is listed once and the result is kept.
    store.clear();
    stats = await visitStats(e);
    assert.equal(todayLists, 1);
    assert.equal(stats.views, 6);
    await visitStats(e);
    assert.equal(todayLists, 1);
  } finally {
    delete globalThis.caches;
  }
});

test("forget has its own small daily cap, refused with 429 {full:true}", async () => {
  const e = env();
  for (let i = 1; i <= LIMITS.forgetsPerDay + 1; i++) assert.equal((await worker.fetch(post({ install: installN(i), reports: [good] }, "9.9." + i + ".1"), e)).status, 200);
  const forget = (n, ip) => new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install: installN(n) }), headers: { "CF-Connecting-IP": ip } });
  const codes = [];
  for (let i = 1; i <= LIMITS.forgetsPerDay; i++) {
    const res = await worker.fetch(forget(i, "7.7.7." + i), e);
    codes.push(res.status);
    assert.equal((await res.json()).deleted, 1);
  }
  assert.deepEqual(codes, Array(LIMITS.forgetsPerDay).fill(200));
  const left = [...e.REPORTS.m.keys()].filter((k) => k.startsWith("r:")).length;
  const res = await worker.fetch(forget(LIMITS.forgetsPerDay + 1, "8.8.8.8"), e);
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "collector is full for today", full: true });
  assert.equal([...e.REPORTS.m.keys()].filter((k) => k.startsWith("r:")).length, left, "a refused forget deletes nothing");
});

test("forgets for unknown ids delete nothing, use no counters, and do not block a real forget", async () => {
  const e = env();
  assert.equal((await worker.fetch(post({ install, reports: [good] }), e)).status, 200);
  const forget = (id) => new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install: id }), headers: { "CF-Connecting-IP": "1.2.3.4" } });
  let writes = 0;
  const put = e.REPORTS.put.bind(e.REPORTS);
  e.REPORTS.put = async (k, v, o) => { writes++; return put(k, v, o); };
  for (let i = 0; i < 5; i++) {
    const res = await worker.fetch(forget(crypto.randomUUID()), e);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, deleted: 0 });
  }
  assert.equal(writes, 0);
  assert.ok(![...e.REPORTS.m.keys()].some((k) => k.startsWith("rl:forget")), "no forget counter was written");
  const res = await worker.fetch(forget(install), e);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).deleted, 1);
  assert.equal(e.REPORTS.m.get("rl:forget-day:" + new Date().toISOString().slice(0, 10)), "1");
});

test("50 hits from one IP write one key", async () => {
  fakeCache();
  try {
    const e = env();
    let writes = 0;
    const put = e.REPORTS.put.bind(e.REPORTS);
    e.REPORTS.put = async (k, v, o) => { writes++; return put(k, v, o); };
    for (let i = 0; i < 50; i++) assert.equal((await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "1.1.1.1" } }), e)).status, 200);
    assert.equal(writes, 1);
    assert.equal([...e.REPORTS.m.keys()].filter((k) => k.startsWith("hit:")).length, 1);
    const stats = await visitStats(e);
    assert.equal(stats.views, 50);
    assert.equal(stats.visitors, 1);
  } finally {
    delete globalThis.caches;
  }
});

test("a day is rolled up only 5 minutes after its UTC midnight end", async () => {
  const e = env();
  const day = new Date().toISOString().slice(0, 10);
  await worker.fetch(new Request("https://x/api/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": "4.4.4.4" } }), e);
  const end = Date.parse(day) + 86400000;
  let stats = await visitStats(e, new Date(end + 60000));
  assert.equal(e.REPORTS.m.has("visits:" + day), false, "not rolled up one minute after midnight");
  assert.equal(stats.days.find((r) => r.day === day).views, 1, "served from the running counter meanwhile");
  stats = await visitStats(e, new Date(end + 6 * 60000));
  assert.deepEqual(JSON.parse(e.REPORTS.m.get("visits:" + day)), { views: 1, visitors: 1, capped: false });
  assert.equal(stats.days.find((r) => r.day === day).views, 1);
});

test("forget stops walking the old r:20 keys from LEGACY_KEYS_UNTIL", async () => {
  const e = env();
  await worker.fetch(post({ install, reports: [good] }), e);
  const reporter = [...e.REPORTS.m.keys()].find((k) => k.startsWith("r:")).split(":")[1];
  e.REPORTS.m.set("r:2026-11-01:" + reporter + ":old-uuid", "[]");
  const prefixes = [];
  const list = e.REPORTS.list.bind(e.REPORTS);
  e.REPORTS.list = async (o) => { prefixes.push(o.prefix); return list(o); };
  const realNow = Date.now;
  Date.now = () => Date.parse(LEGACY_KEYS_UNTIL + "T00:00:00Z") + 1000;
  try {
    const res = await worker.fetch(new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install }), headers: { "CF-Connecting-IP": "1.2.3.4" } }), e);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).deleted, 1);
    assert.deepEqual(prefixes, ["r:" + reporter + ":"]);
  } finally {
    Date.now = realNow;
  }
});

test("random install ids cost no storage scan and are limited per network before any list", async () => {
  const e = env();
  let lists = 0;
  const realList = e.REPORTS.list.bind(e.REPORTS);
  e.REPORTS.list = async (...a) => { lists++; return realList(...a); };
  const forget = (id, ip) => new Request("https://c.example/v1/forget", { method: "POST", body: JSON.stringify({ install: id }), headers: { "CF-Connecting-IP": ip } });
  const ids = Array.from({ length: 25 }, (_, i) => "aaaaaaaa-bbbb-cccc-dddd-" + String(i).padStart(12, "0"));
  const statuses = [];
  for (const id of ids) statuses.push((await worker.fetch(forget(id, "77.88.99.1"), e)).status);
  assert.deepEqual(statuses.slice(0, 20), Array(20).fill(200));
  assert.deepEqual(statuses.slice(20), Array(5).fill(429), "the 21st attempt from one network is refused");
  assert.equal(lists, 20, "one prefix listing per allowed attempt and no legacy scan for ids that were never seen");
  // another network is not affected
  assert.equal((await worker.fetch(forget(ids[0], "88.1.2.3"), e)).status, 200);
});

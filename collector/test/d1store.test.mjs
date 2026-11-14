// The D1-backed store, exercised against a real SQLite engine (node:sqlite) behind the small part of the D1 API it uses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { d1Store, layered, storeFor, D1_BUDGET } from "../d1store.js";
import worker, { LIMITS, visitStats } from "../worker.js";

let DatabaseSync;
try { ({ DatabaseSync } = await import("node:sqlite")); } catch { /* Node without node:sqlite: the tests below are skipped */ }
const skip = DatabaseSync ? false : "node:sqlite is not available in this Node.js";

// D1's prepare/bind/first/run/all and batch, on an in-memory SQLite database.
function fakeD1() {
  const db = new DatabaseSync(":memory:");
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    async first() { return db.prepare(sql).get(...args) ?? null; },
    async all() { return { results: db.prepare(sql).all(...args) }; },
    async run() { const r = db.prepare(sql).run(...args); return { meta: { changes: Number(r.changes) } }; },
    exec() { return db.prepare(sql).run(...args); }
  });
  return { raw: db, prepare: (sql) => statement(sql), async batch(list) { return list.map((s) => s.exec()); } };
}
function kv() {
  const m = new Map();
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
    async delete(k) { m.delete(k); },
    async list({ prefix, cursor, limit = 1000 }) {
      const all = [...m.keys()].filter((k) => k.startsWith(prefix)).sort().filter((k) => !cursor || k > cursor);
      const keys = all.slice(0, limit).map((name) => ({ name }));
      const complete = all.length <= limit;
      return { keys, list_complete: complete, cursor: complete ? undefined : keys[keys.length - 1].name };
    }
  };
}
const listAll = async (store, prefix, limit) => {
  const names = []; let cursor;
  do { const page = await store.list({ prefix, cursor, limit }); names.push(...page.keys.map((k) => k.name)); cursor = page.list_complete ? undefined : page.cursor; } while (cursor);
  return names;
};

test("get, put, overwrite and delete", { skip }, async () => {
  const s = d1Store(fakeD1());
  assert.equal(await s.get("a"), null);
  await s.put("a", "1"); await s.put("a", "2");
  assert.equal(await s.get("a"), "2");
  await s.put("n", 7);
  assert.equal(await s.get("n"), "7", "values are stored as text, like KV");
  await s.delete("a");
  assert.equal(await s.get("a"), null);
});

test("entries expire after their TTL and expired rows are swept on later writes", { skip }, async () => {
  let t = 1_000_000_000_000;
  const d1 = fakeD1();
  const s = d1Store(d1, { now: () => t, random: () => 0 });   // random 0: sweep on every write
  await s.put("short", "x", { expirationTtl: 60 });
  await s.put("keep", "y");
  t += 59_000; assert.equal(await s.get("short"), "x");
  t += 2_000;
  assert.equal(await s.get("short"), null, "not returned once expired");
  assert.deepEqual(await listAll(s, ""), ["keep"], "not listed once expired");
  await s.put("other", "z");
  assert.equal(d1.raw.prepare("SELECT COUNT(*) AS n FROM kv WHERE key = 'short'").get().n, 0, "the expired row is gone from the table");
  await s.put("short", "again", { expirationTtl: 60 });
  assert.equal(await s.get("short"), "again", "a key can be written again after it expired");
});

test("list returns only the prefix, in order, across pages", { skip }, async () => {
  const s = d1Store(fakeD1());
  for (const k of ["r:b:2", "r:a:1", "r:a:2", "r:a:3", "rs:a", "hit:1", "r:a", "q"]) await s.put(k, "v");
  assert.deepEqual(await listAll(s, "r:a:", 2), ["r:a:1", "r:a:2", "r:a:3"]);
  assert.deepEqual(await listAll(s, "r:", 1000), ["r:a", "r:a:1", "r:a:2", "r:a:3", "r:b:2"]);
  assert.deepEqual(await listAll(s, "zzz"), []);
  const first = await s.list({ prefix: "r:", limit: 2 });
  assert.equal(first.list_complete, false);
  assert.equal(first.keys.length, 2);
});

test("layered: reads fall back to the old store, writes go to the new one, deletes reach both", { skip }, async () => {
  const old = kv(), d1 = d1Store(fakeD1()), s = layered(d1, old);
  await old.put("r:x:1", "old"); await old.put("r:x:2", "old2"); await old.put("visits:2026-01-01", "{}");
  await s.put("r:x:3", "new");
  assert.equal(await s.get("r:x:1"), "old");
  assert.equal(await s.get("r:x:3"), "new");
  assert.equal(old.m.has("r:x:3"), false, "nothing new is written to the old store");
  assert.deepEqual((await listAll(s, "r:x:", 1)).sort(), ["r:x:1", "r:x:2", "r:x:3"], "pages cover both stores");
  await s.delete("r:x:1");
  assert.equal(old.m.has("r:x:1"), false);
  assert.equal(await s.get("r:x:1"), null);
  assert.equal(s.budget, D1_BUDGET);
  assert.equal(layered(d1, undefined), d1, "without an old store the new one is used directly");
});

test("the collector on D1: report, export, forget, and data left in KV still counts", { skip }, async () => {
  const env = { DB: fakeD1(), REPORTS: kv(), SALT: "test-salt", EXPORT_TOKEN: "secret-token" };
  const install = "0f8d6c2a-1111-4222-8333-944455556666";
  const post = (path, body) => new Request("https://c.example" + path, { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.4" } });
  // A report this install sent before the move, still in KV under the same anonymous id.
  const first = await worker.fetch(post("/v1/report", { install, reports: [{ type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, calls: 3 }] }), { REPORTS: env.REPORTS, SALT: env.SALT });
  assert.equal(first.status, 200);
  const kvReports = [...env.REPORTS.m.keys()].filter((k) => k.startsWith("r:")).length;
  assert.equal(kvReports, 1);

  const res = await worker.fetch(post("/v1/report", { install, reports: [{ type: "speed", model: "claude-opus-5-5", outputTokens: 500, seconds: 5, calls: 3 }] }), env);
  assert.equal(res.status, 200);
  assert.equal([...env.REPORTS.m.keys()].filter((k) => k.startsWith("r:")).length, kvReports, "the new report did not go to KV");
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM kv WHERE key LIKE 'r:%'").get().n, 1, "it went to D1");
  const text = JSON.stringify(env.DB.raw.prepare("SELECT key, value FROM kv").all());
  assert.ok(!text.includes(install) && !text.includes("1.2.3.4"), "neither the install id nor the IP address is stored");

  const out = await worker.fetch(new Request("https://c.example/v1/export", { headers: { Authorization: "Bearer secret-token" } }), env);
  assert.deepEqual((await out.json()).map((r) => r.model).sort(), ["claude-opus-5-5", "gpt-6-1-sol"], "export covers both stores");

  const gone = await worker.fetch(post("/v1/forget", { install }), env);
  assert.equal((await gone.json()).deleted, 2, "forget deletes from both stores");
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM kv WHERE key LIKE 'r:%'").get().n, 0);
  assert.equal([...env.REPORTS.m.keys()].filter((k) => k.startsWith("r:")).length, 0);
});

test("D1 lifts the daily caps that came from the KV write budget", { skip }, async () => {
  assert.ok(D1_BUDGET.newBatchesPerDay > LIMITS.newBatchesPerDay && D1_BUDGET.knownBatchesPerDay > LIMITS.knownBatchesPerDay);
  const worst = D1_BUDGET.newBatchesPerDay * 6 + D1_BUDGET.knownBatchesPerDay * 3 + D1_BUDGET.forgetsPerDay * 96 + D1_BUDGET.visitWriteCap;
  assert.ok(worst < 100000, "the worst case stays inside D1's free 100,000 row writes a day: " + worst);
  const env = { DB: fakeD1(), REPORTS: kv(), SALT: "s" };
  // More new reporters than the KV cap allowed in one day, each from its own network.
  for (let i = 0; i < LIMITS.newBatchesPerDay + 3; i++) {
    const res = await worker.fetch(new Request("https://c.example/v1/report", { method: "POST", headers: { "Content-Type": "application/json", "CF-Connecting-IP": `10.${i}.0.1` },
      body: JSON.stringify({ install: "install-number-" + String(i).padStart(6, "0"), reports: [{ type: "rating", model: "gpt-6-1-sol", score: 7 }] }) }), env);
    assert.equal(res.status, 200, "reporter " + i);
  }
  assert.equal(storeFor({ REPORTS: env.REPORTS }), env.REPORTS, "without a DB binding KV is used as before");
});

test("visit counting works on D1", { skip }, async () => {
  const env = { DB: fakeD1(), REPORTS: kv(), SALT: "s" };
  for (const ip of ["1.1.1.1", "2.2.2.2", "1.1.1.1"]) {
    await worker.fetch(new Request("https://c.example/v1/hit", { method: "POST", headers: { "CF-Connecting-IP": ip } }), env);
  }
  const stats = await visitStats({ ...env, REPORTS: storeFor(env) });
  const today = stats.days[stats.days.length - 1];
  assert.equal(today.views, 3);
  assert.equal(today.visitors, 2);
});

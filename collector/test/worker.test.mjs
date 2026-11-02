import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { sanitize, LIMITS } from "../worker.js";

function kv() {
  const m = new Map();
  return {
    m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
    async list({ prefix }) { return { keys: [...m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }; }
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
  assert.equal(rows[1].plan, "bPlus/b");
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

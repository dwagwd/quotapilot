import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { aggregate, clean, trimOutliers, stats } from "../scripts/aggregate.mjs";
import { parseIssue, sanitize } from "../scripts/ingest-issue.mjs";

const models = JSON.parse(readFileSync(new URL("../data/models.json", import.meta.url))).models;
const now = new Date("2026-11-02T12:00:00Z");
const day = (d) => new Date(now.getTime() - d * 864e5).toISOString();

test("speed reports become tokens per second", () => {
  const r = clean({ type: "speed", model: "claude-opus-5-5", outputTokens: 900, seconds: 10, date: day(1) }, models);
  assert.equal(r.tps, 90);
  assert.equal(r.provider, "claude");
});

test("invalid reports are rejected", () => {
  assert.equal(clean({ type: "speed", model: "nope", outputTokens: 900, seconds: 10, date: day(1) }, models), null);
  assert.equal(clean({ type: "rating", model: "grok-4-7", score: 11, date: day(1) }, models), null);
  assert.equal(clean({ type: "quota", plan: "Max", window: "monthly", percentUsed: 10, tokensUsed: 5e5, model: "claude-opus-5-5", date: day(1) }, models), null);
  assert.equal(clean({ type: "hack", date: day(1) }, models), null);
});

test("quota estimate scales tokens by percent used", () => {
  const r = clean({ type: "quota", model: "claude-opus-5-5", plan: "Max", window: "5h", percentUsed: 10, tokensUsed: 1e6, inputShare: 0.8, date: day(1) }, models);
  assert.equal(r.estTokens, 1e7);
  assert.equal(Math.round(r.estUsd), 72); // 8M × $4 + 2M × $20
});

test("outliers are trimmed with IQR", () => {
  assert.deepEqual(trimOutliers([10, 11, 12, 13, 14, 500]), [10, 11, 12, 13, 14]);
  assert.equal(stats([10, 20, 30]).median, 20);
});

test("rows below the sample minimum stay hidden, old reports drop out", () => {
  const raw = [
    ...[1, 2].map((i) => ({ type: "speed", model: "grok-4-7", outputTokens: 800, seconds: 10, date: day(i), reporter: "u" + i })),
    ...[1, 2, 3].map((i) => ({ type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(i), reporter: "u" + i })),
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 1, date: day(20), reporter: "old" }
  ];
  const out = aggregate(raw, models, now);
  assert.deepEqual(out.speed.map((s) => s.model), ["gpt-6-1-sol"]);
  assert.equal(out.speed[0].median, 100);
});

test("one reporter cannot stack the same stat on one day", () => {
  const raw = Array.from({ length: 5 }, () => ({ type: "rating", model: "grok-4-7", score: 1, degraded: true, date: day(1), reporter: "spammer" }));
  raw.push(...[1, 2, 3].map((i) => ({ type: "rating", model: "grok-4-7", score: 8, date: day(1), reporter: "u" + i })));
  const out = aggregate(raw, models, now);
  assert.equal(out.ratings[0].n, 4);
  assert.equal(out.ratings[0].avg, 6.3);
});

test("degradation alert fires at 30% of recent ratings", () => {
  const raw = [1, 2, 3].map((i) => ({ type: "rating", model: "claude-opus-5-5", score: 5, degraded: i === 1, date: day(i), reporter: "u" + i }));
  assert.equal(aggregate(raw, models, now).ratings[0].alert, true);
});

test("issue body JSON is parsed and the author attached", () => {
  const res = parseIssue({ body: "hi\n```json\n{\"type\":\"rating\",\"model\":\"grok-4-7\",\"score\":7}\n```", user: { login: "dana" }, created_at: "2026-11-01T00:00:00Z" });
  assert.equal(res.reports[0].reporter, "dana");
  assert.equal(res.reports[0].date, "2026-11-01T00:00:00Z");
  assert.ok(parseIssue({ body: "no json" }).error);
});

test("QuotaPilot summary reports (many calls) are accepted", () => {
  const r = clean({ type: "speed", model: "gpt-6-1-sol", outputTokens: 990314, seconds: 33775, calls: 1274, client: "Codex", via: "quotapilot", date: day(1) }, models);
  assert.ok(Math.abs(r.tps - 29.32) < 0.01);
});

test("effort usage groups by model and effort", () => {
  const raw = [1, 2, 3].flatMap((i) => [
    { type: "speed", model: "gpt-6-1-sol", effort: "high", outputTokens: 6000, reasoningTokens: 3600, seconds: 100, calls: 10, date: day(1), reporter: "u" + i },
    { type: "speed", model: "gpt-6-1-sol", effort: "xhigh", outputTokens: 9000, reasoningTokens: 7200, seconds: 120, calls: 10, date: day(1), reporter: "u" + i },
    { type: "speed", model: "gpt-6-1-sol", effort: "secret-label", outputTokens: 9000, seconds: 120, date: day(1), reporter: "v" + i }
  ]);
  const out = aggregate(raw, models, now);
  assert.deepEqual(out.effortUsage.map((e) => e.effort), ["high", "xhigh"]);
  assert.equal(out.effortUsage[0].perCall, 600);
  assert.equal(out.effortUsage[1].reasoningShare, 0.8);
  assert.equal(out.effortUsage[0].tps, 60);
});

test("issue reports are reduced to known plain fields", () => {
  const evil = { type: "quota", plan: "<img src=x onerror=alert(1)>Max", window: "5h", percentUsed: 10, tokensUsed: 1e6, provider: "claude", extra: "x".repeat(1e5), __proto__: { polluted: true } };
  const clean = sanitize(evil);
  assert.equal(clean.plan, "img src=x onerror=alert(1)Max");
  assert.equal(clean.extra, undefined);
  assert.equal(sanitize("nope"), null);
  assert.ok(parseIssue({ body: "x".repeat(20001) }).error);
  const res = parseIssue({ body: "```json\n[{\"type\":\"rating\",\"model\":\"grok-4-7\",\"score\":7,\"secret\":\"/Users/me\"}]\n```", user: { login: "bad user; rm -rf" }, created_at: "2026-11-01T00:00:00Z" });
  assert.equal(res.reports[0].reporter, "anon");
  assert.equal(res.reports[0].secret, undefined);
});

test("blocked reporters and floods are ignored", () => {
  const raw = Array.from({ length: 100 }, (_, i) => ({ type: "rating", model: "grok-4-7", score: 1, date: day(1), reporter: "flood" }));
  raw.push(...[1, 2, 3].map((i) => ({ type: "rating", model: "grok-4-7", score: 9, date: day(1), reporter: "u" + i })));
  const out = aggregate(raw, models, now, ["u1"]);
  assert.equal(out.ratings[0].n, 3); // flood counts once per day, u1 is blocked
});

test("one person reporting on several days cannot meet the three-people threshold", () => {
  const raw = [1, 2, 3].map((i) => ({ type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(i), reporter: "same-person" }));
  raw.push(...[1, 2, 3].map((i) => ({ type: "rating", model: "grok-4-7", score: 9, date: day(i), reporter: "same-person" })));
  raw.push(...[1, 2, 3].map((i) => ({ type: "quota", model: "claude-opus-5-5", plan: "Max", window: "5h", percentUsed: 10, tokensUsed: 1e6, date: day(i), reporter: "same-person" })));
  raw.push(...[1, 2, 3].map((i) => ({ type: "speed", model: "gpt-6-1-sol", effort: "high", outputTokens: 1000, seconds: 10, date: day(i), reporter: "solo" })));
  const res = aggregate(raw, models, now);
  assert.equal(res.speed.length, 0);
  assert.equal(res.ratings.length, 0);
  assert.equal(res.quota.length, 0);
  assert.equal(res.effortUsage.length, 0);
});

test("each person counts once per row, and report count is kept separately", () => {
  const raw = [
    ...[1, 2, 3, 4, 5].map((i) => ({ type: "speed", model: "gpt-6-1-sol", outputTokens: 5000, seconds: 10, date: day(i), reporter: "heavy" })),
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "a" },
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "b" }
  ];
  const [row] = aggregate(raw, models, now).speed;
  assert.equal(row.n, 3);
  assert.equal(row.reporters, 3);
  assert.equal(row.reports, 7);
  assert.equal(row.median, 100, "the heavy reporter's five reports weigh as one");
});

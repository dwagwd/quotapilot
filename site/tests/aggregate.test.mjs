import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { aggregate, clean, trimOutliers, stats } from "../scripts/aggregate.mjs";
import { sanitize } from "../../collector/schema.js";

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

test("degradation alert fires at 30% of recent ratings once enough people say so", () => {
  const raw = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((i) => ({ type: "rating", model: "claude-opus-5-5", score: 5, degraded: i <= 3, date: day(1 + (i % 3)), reporter: "u" + i }));
  assert.equal(aggregate(raw, models, now).ratings[0].alert, true);
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

test("reports are reduced to known fields", () => {
  const evil = { type: "quota", plan: "<img src=x onerror=alert(1)>Max", window: "5h", percentUsed: 10, tokensUsed: 1e6, provider: "claude", extra: "x".repeat(1e5), __proto__: { polluted: true } };
  const clean = sanitize(evil);
  assert.equal(clean.plan, undefined, "markup is rejected, not cleaned up");
  assert.equal(clean.window, "5h");
  assert.equal(clean.extra, undefined);
  assert.equal(sanitize("nope"), null);
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

const ymd = (d) => day(d).slice(0, 10);
// A collector report as stored by the worker: received `d` days ago, reporter first seen `firstSeenAgo` days ago.
const fromCollector = (reporter, ipGroup, { d = 1, firstSeenAgo = 5, tokens = 1000 } = {}) => ({
  type: "speed", model: "gpt-6-1-sol", outputTokens: tokens, seconds: 10, date: day(d), reporter,
  reporterFirstSeen: ymd(firstSeenAgo), receivedDay: ymd(d), ipGroup
});

test("many reporters from one network on one day count as one person", () => {
  const fakes = [1, 2, 3, 4, 5].map((i) => fromCollector("anon-fake" + i, "aaaaaaaa", { tokens: 3000 }));
  assert.equal(aggregate(fakes, models, now).speed.length, 0, "five install ids on one network cannot publish");
  const raw = [...fakes, fromCollector("anon-real1", "bbbbbbbb"), fromCollector("anon-real2", "cccccccc")];
  const [row] = aggregate(raw, models, now).speed;
  assert.equal(row.reporters, 3);
  assert.equal(row.n, 3);
  assert.equal(row.median, 100, "the five fakes weigh as one value");
  // Sharing a network on one day links reporters even if they report from elsewhere on other days.
  const linked = [fromCollector("anon-x", "aaaaaaaa"), fromCollector("anon-y", "aaaaaaaa"), fromCollector("anon-y", "dddddddd", { d: 2 }), fromCollector("anon-z", "eeeeeeee")];
  assert.equal(aggregate(linked, models, now).speed.length, 0);
});

test("brand-new reporters only count once they report on a later day", () => {
  const fresh = [1, 2, 3].map((i) => fromCollector("anon-new" + i, "0000000" + i, { firstSeenAgo: 1 }));
  assert.equal(aggregate(fresh, models, now).speed.length, 0, "first seen the same day as their only report");
  // One of them reports again the next day: all of their reports now count.
  const later = [...fresh, fromCollector("anon-new1", "00000009", { d: 0, firstSeenAgo: 1 })];
  assert.equal(aggregate(later, models, new Date(now.getTime() + 864e5 / 4)).speed.length, 0, "still only one established reporter");
  const aged = fresh.map((r) => ({ ...r, reporterFirstSeen: ymd(3) }));
  assert.equal(aggregate(aged, models, now).speed[0].reporters, 3);
  // Two distinct received days also establish a reporter (its first-seen record may have expired and restarted).
  const twoDays = [1, 2, 3].flatMap((i) => [fromCollector("anon-r" + i, "1000000" + i, { d: 1, firstSeenAgo: 1 }), { ...fromCollector("anon-r" + i, "2000000" + i, { d: 2, firstSeenAgo: 2 }) }]);
  assert.equal(aggregate(twoDays, models, now).speed[0].reporters, 3);
  // The client-supplied date cannot fake age: only the collector's days are compared.
  const backdated = [1, 2, 3].map((i) => ({ ...fromCollector("anon-b" + i, "3000000" + i, { firstSeenAgo: 1 }), date: day(3) }));
  assert.equal(aggregate(backdated, models, now).speed.length, 0);
});

test("legacy reports without the new fields still count", () => {
  const raw = [
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "anon-old1" },
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "anon-old2" },
    fromCollector("anon-new", "abcdef01")
  ];
  const [row] = aggregate(raw, models, now).speed;
  assert.equal(row.reporters, 3);
});

test("each person counts once per row, and report count is kept separately", () => {
  const raw = [
    ...[1, 2, 3, 4, 5].map((i) => ({ type: "speed", model: "gpt-6-1-sol", outputTokens: 3000, seconds: 10, date: day(i), reporter: "heavy" })),
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "a" },
    { type: "speed", model: "gpt-6-1-sol", outputTokens: 1000, seconds: 10, date: day(1), reporter: "b" }
  ];
  const [row] = aggregate(raw, models, now).speed;
  assert.equal(row.n, 3);
  assert.equal(row.reporters, 3);
  assert.equal(row.reports, 7);
  assert.equal(row.median, 100, "the heavy reporter's five reports weigh as one");
});

test("token mix shows prompt per output and cache hit once three people report it", () => {
  const rep = (who, input, read, write) => ({ type: "speed", model: "claude-opus-5-5", outputTokens: 1000, seconds: 10, inputTokens: input, cacheReadTokens: read, cacheWriteTokens: write, date: day(1), reporter: who });
  const two = aggregate([rep("a", 100, 9000, 900), rep("b", 200, 8000, 800)], models, now);
  assert.deepEqual(two.tokenMix, []);
  const three = aggregate([rep("a", 100, 9000, 900), rep("b", 200, 8000, 800), rep("c", 1000, 18000, 1000), { type: "speed", model: "claude-opus-5-5", outputTokens: 1000, seconds: 10, date: day(1), reporter: "d" }], models, now);
  const row = three.tokenMix.find((r) => r.model === "claude-opus-5-5");
  assert.equal(row.n, 3, "reports without prompt data are not counted");
  assert.equal(row.inputPerOutput, 10);   // person medians 10, 9, 20 -> 10
  assert.equal(row.cacheHit, 0.9);        // 0.9, 0.889, 0.9 -> 0.9
  assert.ok(row.cacheWriteShare > 0.04 && row.cacheWriteShare < 0.1);
});

test("prompt fields are bounded numbers", () => {
  const r = clean({ type: "speed", model: "gpt-6-1-sol", outputTokens: 900, seconds: 10, inputTokens: -5, cacheReadTokens: 10, cacheWriteTokens: 0, date: day(1) }, models);
  assert.equal(r.inputPerOutput, null);
  assert.equal(r.cacheHit, null);
});

test("limit events stay hidden until three people report them for a provider", () => {
  const ev = (who, h) => ({ type: "event", provider: "chatgpt", plan: "Plus", kind: "hit_limit", date: new Date(now.getTime() - 864e5 + h * 36e5).toISOString(), reporter: who });
  const one = aggregate([ev("a", 1), ev("a", 2), ev("a", 3)], models, now);
  assert.equal(one.events.byHourUtc.chatgpt.reduce((a, b) => a + b, 0), 0, "one person's working hours are not published");
  assert.deepEqual(one.events.counts, []);
  const three = aggregate([ev("a", 1), ev("b", 2), ev("c", 3)], models, now);
  assert.equal(three.events.byHourUtc.chatgpt.reduce((a, b) => a + b, 0), 3);
});

test("implausible or backdated reports are dropped before they reach a row", () => {
  const base = { type: "speed", model: "claude-opus-5-5", calls: 10, receivedDay: "2026-11-02", date: "2026-11-02T08:00:00Z" };
  assert.ok(clean({ ...base, outputTokens: 10000, seconds: 200 }, models), "50 tok/s is fine");
  assert.equal(clean({ ...base, outputTokens: 1e7, seconds: 10 }, models), null, "1M tok/s is not");
  assert.equal(clean({ ...base, outputTokens: 10000, seconds: 20000 }, models), null, "2000 s per call is not");
  assert.equal(clean({ ...base, outputTokens: 10000, seconds: 200, date: "2026-10-01T00:00:00Z" }, models), null, "backdated");
  assert.equal(clean({ ...base, outputTokens: 10000, seconds: 200, date: "2026-11-05T00:00:00Z" }, models), null, "from the future");
  const r = clean({ ...base, outputTokens: 10000, seconds: 200, inputTokens: 1e11, cacheReadTokens: 0, cacheWriteTokens: 0 }, models);
  assert.equal(r.inputPerOutput, null, "absurd prompt totals are ignored, speed is kept");
  assert.equal(clean({ type: "quota", provider: "claude", plan: "Max", window: "5h", percentUsed: 0.5, tokensUsed: 1e9, date: day(1) }, models), null);
});

test("a feels-worse warning needs five people and three of them saying so", () => {
  const rate = (who, degraded) => ({ type: "rating", model: "grok-4-7", score: 5, degraded, date: day(1), reporter: who });
  const two = aggregate([rate("a", true), rate("b", true), rate("c", false), rate("d", false), rate("e", false)], models, now);
  assert.equal(two.ratings[0].alert, false);
  const three = aggregate([rate("a", true), rate("b", true), rate("c", true), rate("d", false), rate("e", false)], models, now);
  assert.equal(three.ratings[0].alert, true);
  const few = aggregate([rate("a", true), rate("b", true), rate("c", true)], models, now);
  assert.equal(few.ratings[0].alert, false, "three people make a row, not a warning");
});

const hit = (who, date, resetAt) => ({ type: "event", provider: "chatgpt", plan: "Plus", kind: "hit_limit", date, ...(resetAt ? { resetAt } : {}), reporter: who });
const eventTotal = (out) => out.events.byHourUtc.chatgpt.reduce((a, b) => a + b, 0);

test("one limit episode lasting several days counts once, and counts are people", () => {
  const reset = "2026-11-03T10:00:00Z";
  const raw = [
    hit("a", "2026-10-30T10:00:00Z", reset), hit("a", "2026-10-31T10:00:00Z", reset), hit("a", "2026-11-01T10:00:00Z", reset),
    hit("b", "2026-11-01T09:00:00Z", "2026-11-03T09:00:00Z"),
    hit("c", "2026-11-01T08:00:00Z"), hit("c", "2026-11-01T08:00:00Z")
  ];
  const out = aggregate(raw, models, now);
  assert.equal(eventTotal(out), 3, "a's three days are one episode, c's repeat is the same hour");
  assert.deepEqual(out.events.counts, [{ provider: "chatgpt", kind: "hit_limit", n: 3 }]);
  // A second, different episode adds an event but not a person.
  const more = aggregate([...raw, hit("a", "2026-10-28T10:00:00Z", "2026-10-29T10:00:00Z")], models, now);
  assert.equal(eventTotal(more), 4);
  assert.equal(more.events.counts[0].n, 3, "n is the number of people, not reports");
});

test("resetAt is accepted only within eight days after the event hour", () => {
  const base = { type: "event", provider: "chatgpt", kind: "hit_limit", date: "2026-10-30T10:00:00Z" };
  assert.equal(clean({ ...base, resetAt: "2026-10-30T15:00:00Z" }, models).resetAt, "2026-10-30T15:00:00.000Z");
  assert.equal(clean({ ...base, resetAt: "2026-10-30T09:00:00Z" }, models).resetAt, null, "before the event");
  assert.equal(clean({ ...base, resetAt: "2026-11-08T10:00:01Z" }, models).resetAt, null, "more than 8 days later");
  assert.equal(clean({ ...base, resetAt: "nonsense" }, models).resetAt, null);
  assert.equal(clean(base, models).resetAt, null);
});

const siteReport = (who, ipGroup) => ({ ...fromCollector(who, ipGroup, { firstSeenAgo: 1 }), via: "site" });

test("a one-shot site reporter with a unique network is established, but cannot publish a row alone", () => {
  const raw = [siteReport("anon-s1", "11111111"), siteReport("anon-s2", "22222222"), siteReport("anon-s3", "33333333")];
  const out = aggregate(raw, models, now);
  assert.equal(out.speed.length, 0, "three one-shot site reporters are not enough");
  assert.equal(out.totals.established, 3);
  const mixed = [raw[0], raw[1], fromCollector("anon-reg", "55555555")];
  assert.equal(aggregate(mixed, models, now).speed[0].reporters, 3, "one regular reporter anchors the row");
  // The same one-shot reports from QuotaPilot keep the normal rule and do not count yet.
  const qp = raw.map((r) => ({ ...r, via: "quotapilot" }));
  assert.equal(aggregate(qp, models, now).speed.length, 0);
});

test("a site reporter sharing a network with another reporter that day does not count", () => {
  const raw = [siteReport("anon-x", "aaaaaaaa"), siteReport("anon-y", "aaaaaaaa"), siteReport("anon-z", "33333333"), siteReport("anon-w", "44444444")];
  const out = aggregate(raw, models, now);
  assert.equal(out.speed.length, 0, "only the two unique-network reporters count");
  assert.equal(out.totals.established, 2);
});

test("5-hour quota reports under 10% are ignored and published quota rows are lower bounds", () => {
  const q = (window, pct) => ({ type: "quota", model: "claude-opus-5-5", plan: "Max", window, percentUsed: pct, tokensUsed: 1e6, date: day(1) });
  assert.equal(clean(q("5h", 5), models), null);
  assert.ok(clean(q("5h", 10), models));
  assert.ok(clean(q("weekly", 5), models), "the weekly window is not affected");
  const raw = [1, 2, 3].map((i) => ({ ...q("weekly", 5), reporter: "u" + i }));
  const out = aggregate(raw, models, now);
  assert.equal(out.quota.length, 1);
  assert.equal(out.quota[0].lowerBound, true);
  const five = [1, 2, 3].map((i) => ({ ...q("5h", 5), reporter: "u" + i }));
  assert.equal(aggregate(five, models, now).quota.length, 0);
});

test("ratings, quota and events also need a unit that is not a one-shot site reporter", () => {
  const site = (r, i) => ({ ...r, reporter: "anon-t" + i, reporterFirstSeen: ymd(1), receivedDay: ymd(1), ipGroup: "6000000" + i, via: "site" });
  const regular = (r) => ({ ...r, reporter: "anon-reg", reporterFirstSeen: ymd(5), receivedDay: ymd(1), ipGroup: "70000000" });
  const rating = { type: "rating", model: "grok-4-7", score: 8, date: day(1) };
  const quotaReport = { type: "quota", model: "claude-opus-5-5", plan: "Max", window: "weekly", percentUsed: 5, tokensUsed: 1e6, date: day(1) };
  const ev = { type: "event", provider: "chatgpt", plan: "Plus", kind: "hit_limit", date: day(1) };
  const kinds = [rating, quotaReport, ev];
  const only = aggregate(kinds.flatMap((r) => [1, 2, 3].map((i) => site(r, i))), models, now);
  assert.equal(only.ratings.length, 0);
  assert.equal(only.quota.length, 0);
  assert.equal(eventTotal(only), 0);
  const mixed = aggregate(kinds.flatMap((r) => [site(r, 1), site(r, 2), regular(r)]), models, now);
  assert.equal(mixed.ratings.length, 1);
  assert.equal(mixed.quota.length, 1);
  assert.equal(eventTotal(mixed), 3);
});

test("an optional metric is published only when 3 people supplied it, even if the row has 3 people", () => {
  const raw = [1, 2, 3].map((i) => ({ type: "speed", model: "gpt-6-1-sol", effort: "high", outputTokens: 6000, seconds: 100, calls: 10, date: day(1), reporter: "u" + i,
    ...(i === 1 ? { reasoningTokens: 3600 } : {}) }));
  const row = aggregate(raw, models, now).effortUsage[0];
  assert.equal(row.n, 3);
  assert.equal(row.reasoningShare, null, "one person's reasoning share must not appear");
  const withThree = [1, 2, 3].map((i) => ({ ...raw[i - 1], reasoningTokens: 3600 }));
  assert.equal(aggregate(withThree, models, now).effortUsage[0].reasoningShare, 0.6);
});

test("1 or 2 people give a coarse preliminary row, never quartiles, and 3 people move it to the published rows", () => {
  const sp = (who, tokens, d) => ({ type: "speed", model: "claude-opus-5-5", outputTokens: tokens, seconds: 10, calls: 4, date: day(d), reporter: who, reporterFirstSeen: day(9).slice(0, 10), receivedDay: day(d).slice(0, 10) });
  const qu = (who, d) => ({ type: "quota", provider: "claude", plan: "Max 5x", window: "weekly", percentUsed: 40, tokensUsed: 12345678, date: day(d), reporter: who, reporterFirstSeen: day(9).slice(0, 10), receivedDay: day(d).slice(0, 10) });
  const one = aggregate([sp("a", 860, 1), sp("a", 864, 2), qu("a", 1)], models, now);
  assert.equal(one.speed.length, 0);
  assert.deepEqual(one.preliminary.speed, [{ model: "claude-opus-5-5", n: 1, median: 85 }]);
  assert.deepEqual(Object.keys(one.preliminary.speed[0]).sort(), ["median", "model", "n"]);
  assert.equal(one.preliminary.quota.length, 1);
  assert.equal(one.preliminary.quota[0].medianTokens, 31000000);  // 12,345,678 / 40% = 30.9M, 2 significant figures
  assert.equal(one.preliminary.quota[0].p25Tokens, undefined);
  assert.equal(one.events.counts.length, 0);
  const three = aggregate(["a", "b", "c"].map((w) => sp(w, 870, 1)), models, now);
  assert.equal(three.speed.length, 1);
  assert.equal(three.preliminary.speed.length, 0);
});

test("a preliminary quota row needs a plan from the fixed list", () => {
  const qu = (plan) => ({ type: "quota", provider: "claude", plan, window: "weekly", percentUsed: 40, tokensUsed: 12345678, date: day(1), reporter: "a", reporterFirstSeen: day(9).slice(0, 10), receivedDay: day(1).slice(0, 10) });
  assert.equal(aggregate([qu("Call me at 555-1234")], models, now).preliminary.quota.length, 0);
  assert.equal(aggregate([qu("Acme Corp")], models, now).preliminary.quota.length, 0);
  assert.equal(aggregate([qu("Max 5x")], models, now).preliminary.quota.length, 1);
  assert.equal(aggregate([qu("  max 20X ")], models, now).preliminary.quota.length, 1);
});

test("a one-shot website report alone never makes a preliminary row", () => {
  const r = { type: "speed", model: "claude-opus-5-5", outputTokens: 900, seconds: 10, calls: 4, date: day(1), reporter: "site1", via: "site", ipGroup: "abcdef12", reporterFirstSeen: day(1).slice(0, 10), receivedDay: day(1).slice(0, 10) };
  assert.equal(aggregate([r], models, now).preliminary.speed.length, 0);
});

// ---- local runs ----
const lr = (who, d, over = {}) => ({ type: "localrun", localModel: "qwen3-a3b-instruct", paramsB: 30, quant: "Q4_K_M", engine: "ollama", engineVersion: "0.5", chip: "Apple M4 Max", memGB: 64, gpuCores: 40,
  os: "macos", osMajor: 26, genTps: 70, promptTps: 600, samples: 8, date: day(d), reporter: who, reporterFirstSeen: day(9).slice(0, 10), receivedDay: day(d).slice(0, 10), ...over });

test("local runs: 3 people publish a row grouped by model, quantization, engine, chip and memory tier", () => {
  const raw = [lr("a", 1, { genTps: 60 }), lr("b", 1, { genTps: 70 }), lr("c", 1, { genTps: 80 }), lr("d", 1, { engine: "llamacpp", genTps: 90 })];
  const out = aggregate(raw, models, now);
  assert.equal(out.localRuns.rows.length, 1);
  const row = out.localRuns.rows[0];
  assert.deepEqual({ model: row.model, paramsB: row.paramsB, quant: row.quant, engine: row.engine, chip: row.chip, memGB: row.memGB, n: row.n },
    { model: "qwen3-a3b-instruct", paramsB: 30, quant: "Q4_K_M", engine: "ollama", chip: "Apple M4 Max", memGB: 64, n: 3 });
  assert.equal(row.genTps, 70);
  assert.equal(row.samples, 24);
  assert.equal(row.promptTps, 600);
  // the llama.cpp report is one person: a separate, preliminary row, rounded to 5 tok/s with no quartiles
  assert.deepEqual(out.localRuns.preliminary, [{ model: "qwen3-a3b-instruct", paramsB: 30, quant: "Q4_K_M", engine: "llamacpp", chip: "Apple M4 Max", memGB: 64, n: 1, genTps: 90 }]);
});

test("local runs: one person never appears as a published row, and exact speeds stay private", () => {
  const out = aggregate([lr("a", 1, { genTps: 71.3 }), lr("a", 2, { genTps: 72.9 })], models, now);
  assert.equal(out.localRuns.rows.length, 0);
  assert.equal(out.localRuns.preliminary.length, 1);
  assert.equal(out.localRuns.preliminary[0].genTps, 70);
  assert.equal(out.localRuns.preliminary[0].genP25, undefined);
  assert.equal(out.localRuns.preliminary[0].promptTps, undefined);
  assert.equal(out.localRuns.preliminary[0].samples, undefined);
  // different memory tiers are different rows
  const split = aggregate([lr("a", 1), lr("b", 1, { memGB: 128 }), lr("c", 1, { memGB: 128 })], models, now);
  assert.equal(split.localRuns.rows.length, 0);
  assert.equal(split.localRuns.preliminary.length, 2);
});

test("local runs: a one-shot site sender cannot be the only person behind a row", () => {
  const site = (who) => lr(who, 1, { via: "site", ipGroup: "abcdef1" + who.length, reporterFirstSeen: day(1).slice(0, 10) });
  assert.equal(aggregate([site("x")], models, now).localRuns.preliminary.length, 0);
});

test("local runs: implausible claims are rejected", () => {
  const bad = (over) => clean(lr("a", 1, over), models);
  assert.ok(bad({}), "baseline is valid");
  assert.equal(bad({ genTps: 4000 }), null, "a 30B model does not generate 4000 tok/s");
  assert.equal(bad({ paramsB: 70, quant: "Q8_0", memGB: 16, genTps: 5 }), null, "70B at 8 bits does not fit in 16 GB");
  assert.equal(bad({ samples: 2 }), null, "fewer than 3 samples");
  assert.equal(bad({ localModel: "acme-secret" }), null);
  assert.equal(bad({ chip: "Apple M4 Max of Danny" }), null);
  assert.equal(bad({ memGB: 36 }), null);
  assert.equal(bad({ genTps: undefined, promptTps: undefined }), null);
  assert.equal(bad({ date: day(-3) }), null, "future dates");
  assert.equal(bad({ receivedDay: day(30).slice(0, 10) }), null, "backdated");
});

test("local runs: one report per person and group per day", () => {
  const out = aggregate([lr("a", 1, { genTps: 10 }), lr("a", 1, { genTps: 70 }), lr("b", 1), lr("c", 1)], models, now);
  assert.equal(out.localRuns.rows[0].reports, 3);
});

test("local runs stay out of the other statistics", () => {
  const out = aggregate([lr("a", 1), lr("b", 1), lr("c", 1)], models, now);
  assert.equal(out.speed.length, 0);
  assert.equal(out.preliminary.speed.length, 0);
  assert.equal(out.totals.reports, 3);
});

test("local runs: an id outside the strict grammar never becomes a row, not even a preliminary one", () => {
  const out = aggregate([lr("a", 1, { localModel: "llama-buy-scamcoin-now" })], models, now);
  assert.equal(out.localRuns.preliminary.length, 0);
  assert.equal(out.localRuns.rows.length, 0);
  assert.equal(clean(lr("a", 1, { localModel: "llama-buy-scamcoin-now" }), models), null);
});

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Browser scripts set globals on window; run them against a plain object.
const run = (file) => { const w = {}; new Function("window", readFileSync(new URL("../assets/" + file, import.meta.url), "utf8"))(w); return w; };
const S = run("community-state.js").AQW_STATE;
const I18N = run("i18n.js").I18N;
const tr = (lang) => (k) => I18N[lang][k] ?? k;
const load = (f) => JSON.parse(readFileSync(new URL("../data/" + f, import.meta.url), "utf8"));

test("the shipped empty community.json publishes nothing, so the invite card shows", () => {
  const c = load("community.json");
  assert.equal(S.publishedCount(c), 0);
  assert.equal(S.eventTotal(c), 0);
});

test("the sample fixture publishes rows, so the card grid shows", () => {
  const c = load("community.sample.json");
  assert.ok(S.publishedCount(c) > 0);
});

test("publishedCount counts every row kind and tolerates missing arrays", () => {
  assert.equal(S.publishedCount(null), 0);
  assert.equal(S.publishedCount({}), 0);
  assert.equal(S.publishedCount({ speed: [{}], ratings: [{}, {}], quota: [], tokenMix: [{}] }), 4);
  assert.equal(S.publishedCount({ speed: [], ratings: [], quota: [{}] }), 1);
});

test("statMeta shows n people, the day window and a UTC timestamp", () => {
  const m = S.statMeta({ n: 7, days: 7, generated: "2026-11-05T19:55:12Z", now: "2026-11-06T00:00:00Z" }, tr("en"));
  assert.match(m.text, /n = 7 people/);
  assert.match(m.text, /last 7 days/);
  assert.match(m.text, /2026-11-05 19:55 UTC/);
  assert.equal(m.stale, false);
  const zh = S.statMeta({ n: 5, days: 7, generated: "2026-11-05T19:55:12Z", now: "2026-11-06T00:00:00Z" }, tr("zh"));
  assert.match(zh.text, /n = 5 人/);
  assert.match(zh.text, /2026-11-05 19:55 UTC/);
});

test("statMeta without a card-wide n says that row n counts people", () => {
  const m = S.statMeta({ days: 7, perRow: true, generated: "2026-11-05T19:55:00Z" }, tr("en"));
  assert.ok(m.parts[0] === I18N.en["stat.nNote"]);
  assert.doesNotMatch(m.text, /n = \d/);
  const events = S.statMeta({ days: 30, generated: "2026-11-05T19:55:00Z" }, tr("en"));
  assert.match(events.text, /^last 30 days/);
});

test("compiled date is stale after 48 hours", () => {
  const gen = "2026-11-05T12:00:00Z";
  assert.equal(S.isStale(gen, "2026-11-07T11:00:00Z"), false); // 47 h
  assert.equal(S.isStale(gen, "2026-11-07T13:00:00Z"), true);  // 49 h
  assert.equal(S.isStale("", "2026-11-07T13:00:00Z"), true);
  assert.equal(S.isStale("not a date"), true);
  assert.equal(S.statMeta({ days: 7, generated: gen, now: "2026-11-08T00:00:00Z" }, tr("en")).stale, true);
});

test("fmtUtc formats to minutes in UTC", () => {
  assert.equal(S.fmtUtc("2026-11-05T19:55:59.999Z"), "2026-11-05 19:55");
  assert.equal(S.fmtUtc(""), "");
  assert.equal(S.fmtUtc("nope"), "");
});

test("copy joins command lines with && into one line", () => {
  assert.equal(S.joinCommands("brew tap a b\nbrew install c\n"), "brew tap a b && brew install c");
  assert.equal(S.joinCommands("  one  \r\n\r\n two "), "one && two");
  assert.equal(S.joinCommands(""), "");
});

test("sponsor link is used only when it is a valid https URL", () => {
  assert.equal(S.sponsorHref({ sponsor: { url: "https://github.com/sponsors/dwagwd" } }), "https://github.com/sponsors/dwagwd");
  assert.equal(S.sponsorHref({ sponsor: { url: "" } }), "");
  assert.equal(S.sponsorHref({ sponsor: { url: "http://example.com" } }), "");
  assert.equal(S.sponsorHref({ sponsor: { url: "javascript:alert(1)" } }), "");
  assert.equal(S.sponsorHref({ sponsor: { url: "not a url" } }), "");
  assert.equal(S.sponsorHref({}), "");
  assert.equal(S.sponsorHref(undefined), "");
});

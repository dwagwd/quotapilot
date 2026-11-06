import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const w = {}; new Function("window", read("../assets/i18n.js"))(w);
const { en, zh } = w.I18N;
const html = read("../index.html");
const app = read("../assets/app.js");

test("en and zh have exactly the same keys and no empty strings", () => {
  assert.deepEqual(Object.keys(zh).sort(), Object.keys(en).sort());
  for (const lang of [en, zh]) for (const [k, v] of Object.entries(lang)) {
    if (k === "sup.none") continue; // intentionally empty
    assert.ok(typeof v === "string" && v.trim(), k);
  }
});

test("placeholders like {n} match between languages", () => {
  const ph = (s) => [...new Set(s.match(/\{[a-z]+\}/g) || [])].sort();
  for (const k of Object.keys(en)) assert.deepEqual(ph(zh[k]), ph(en[k]), k);
});

test("every redesign string exists in both languages", () => {
  const keys = [
    "hero.kicker", "hero.title", "hero.lede", "hero.for", "hero.ctaQp", "hero.ctaPlans", "hero.trust1", "hero.trust2", "hero.trust3",
    "install.title", "install.copy", "install.copied", "install.copyManual", "install.req", "install.prereq", "install.notes", "install.source",
    "nav.tools", "nav.install", "sponsor.label", "sponsor.title", "sponsor.sub", "sponsor.cta", "sponsor.hero",
    "empty.title", "empty.sub", "empty.s1", "empty.s2", "empty.s3", "empty.cta", "empty.alt", "empty.meta", "empty.inline", "empty.sponsor",
    "stat.people", "stat.window", "stat.compiled", "stat.nNote", "stat.lower", "stat.lowerHelp", "stat.method", "stat.staleNote",
    "com.reporters1", "com.reportersN", "foot.privacy", "foot.method", "foot.source", "foot.sponsor", "foot.text", "foot.language",
    "theme.label", "theme.auto", "theme.light", "theme.dark", "glance.reviewed", "glance.compiled",
    "method.title", "method.collector", "method.privacy", "method.aggregate"
  ];
  for (const k of keys) { assert.ok(en[k], "en " + k); assert.ok(zh[k], "zh " + k); }
});

test("strings for removed features are gone", () => {
  for (const k of ["ad.label", "live.visits", "live.views", "foot.visits", "live.fastest", "live.noReports", "footer.text", "tool.title", "hero.reviewed", "com.empty"]) {
    assert.equal(k in en, false, k);
    assert.equal(k in zh, false, k);
  }
});

test("every key used by index.html and app.js is defined", () => {
  const used = [...html.matchAll(/data-i18n(?:-[a-z]+)?="([^"]+)"/g), ...app.matchAll(/\bt\("([^"]+)"\)/g)].map((m) => m[1]);
  assert.ok(used.length > 50);
  for (const k of used) assert.ok(k in en, k);
});

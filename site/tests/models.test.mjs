import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, rmSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadCore, modelsPages } from "../scripts/models-pages.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const read = (p) => readFileSync(join(root, p), "utf8");
const models = JSON.parse(read("data/models.json"));
const M = loadCore(root);
const emptyCommunity = { generated: "2026-11-26T00:00:00Z", speed: [], ratings: [], preliminary: { speed: [], quota: [] }, localRuns: { rows: [], preliminary: [] } };
const community = {
  generated: "2026-11-26T00:00:00Z",
  speed: [{ model: "claude-opus-5-5", median: 62.5, n: 4 }], ratings: [{ model: "claude-opus-5-5", avg: 8.2, n: 5 }],
  preliminary: { speed: [{ model: "gpt-6-1-sol", median: 85, n: 2 }], quota: [] },
  localRuns: {
    rows: [{ model: "qwen3-a3b-instruct", paramsB: 30, quant: "Q4_K_M", engine: "ollama", chip: "Apple M4 Max", memGB: 64, n: 3, genTps: 72.4, promptTps: 640, samples: 30 }],
    preliminary: [{ model: "llama3-1", paramsB: 8, quant: "Q8_0", engine: "llamacpp", chip: "Apple M2", memGB: 16, n: 1, genTps: 35 }]
  }
};

test("blended price uses 3 input : 1 output at list price", () => {
  assert.equal(M.blended({ input: 4, output: 20 }), 8);
  assert.equal(M.blended({ input: 2, output: null }), null);
  assert.equal(M.usd(0.2), "$0.20");
  assert.equal(M.usd(8), "$8");
  assert.equal(M.usd(null), "—");
});

test("cloud rows carry every model with prices, context, community speed and rating", () => {
  const rows = M.cloudRows(models, community);
  assert.equal(rows.length, models.models.length);
  const opus = rows.find((r) => r.id === "claude-opus-5-5");
  assert.deepEqual({ input: opus.input, output: opus.output, cacheRead: opus.cacheRead, blended: opus.blended, ctx: opus.contextTokens }, { input: 4, output: 20, cacheRead: 0.2, blended: 8, ctx: 1e6 });
  assert.deepEqual(opus.speed, { value: 62.5, n: 4, prelim: false });
  assert.deepEqual(opus.rating, { avg: 8.2, n: 5 });
  assert.deepEqual(rows.find((r) => r.id === "gpt-6-1-sol").speed, { value: 85, n: 2, prelim: true });
  assert.equal(rows.find((r) => r.id === "grok-4-7").speed, null);
  for (const r of rows) assert.equal(r.smartness, null, "no model has a smartness value");
});

test("local rows come only from community data, grouped as published", () => {
  assert.equal(M.localRows(emptyCommunity).length, 0);
  assert.equal(M.localRows({}).length, 0);
  const rows = M.localRows(community);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].name, "qwen3-a3b-instruct 30B Q4_K_M");
  assert.equal(rows[0].prelim, false);
  assert.equal(rows[1].prelim, true);
  assert.equal(rows[1].promptTps, null, "preliminary rows carry no prompt speed");
});

test("sorting keeps rows without a value last in both directions; default order is cheapest cloud then fastest local", () => {
  const rows = [...M.cloudRows(models, community), ...M.localRows(community)];
  for (const dir of ["asc", "desc"]) {
    const sorted = M.sortRows(rows, "speed", dir);
    const values = sorted.map((r) => (r.speed ? r.speed.value : null));
    const firstNull = values.indexOf(null);
    assert.ok(values.slice(firstNull).every((v) => v === null), dir);
    const present = values.slice(0, firstNull);
    assert.deepEqual(present, [...present].sort((a, b) => (dir === "asc" ? a - b : b - a)));
  }
  const order = M.defaultOrder(rows);
  const cloud = order.filter((r) => r.kind === "cloud");
  assert.deepEqual(cloud.map((r) => r.blended), [...cloud.map((r) => r.blended)].sort((a, b) => a - b));
  assert.equal(order.findIndex((r) => r.kind === "local"), cloud.length, "local rows follow the cloud rows");
  assert.equal(order.filter((r) => r.kind === "local")[0].speed.value, 72.4);
});

test("filters: type, provider, budget and my hardware", () => {
  const rows = [...M.cloudRows(models, community), ...M.localRows(community)];
  assert.ok(M.filterRows(rows, { type: "local" }).every((r) => r.kind === "local"));
  assert.ok(M.filterRows(rows, { type: "cloud", provider: "claude" }).every((r) => r.provider === "claude"));
  assert.equal(M.filterRows(rows, { provider: "claude" }).filter((r) => r.kind === "local").length, 0);
  const cheap = M.filterRows(rows, { type: "cloud", maxBlended: 2 });
  assert.ok(cheap.length > 0 && cheap.every((r) => r.blended <= 2));
  const mine = M.filterRows(rows, { chip: "Apple M4 Max", mem: "64" });
  assert.deepEqual(mine.map((r) => r.kind), ["local"]);
  assert.equal(M.filterRows(rows, { chip: "Apple M4 Max", mem: "16" }).length, 0);
  assert.equal(M.filterRows(rows, {}).length, rows.length);
});

test("monthly cost: cloud tokens at list price with a cache share, local by electricity for the time the speed implies", () => {
  const opus = M.cloudRows(models, community).find((r) => r.id === "claude-opus-5-5");
  assert.equal(M.monthlyCloudUsd(opus, { inputM: 10, outputM: 2, cachedShare: 0 }), 10 * 4 + 2 * 20);
  assert.equal(M.monthlyCloudUsd(opus, { inputM: 10, outputM: 2, cachedShare: 0.5 }), 5 * 4 + 5 * 0.2 + 2 * 20);
  const local = M.localRows(community)[0];
  // 2M output tokens at 72.4 tok/s plus 10M prompt tokens at 640 tok/s
  const seconds = (2e6 / 72.4) + (10e6 / 640);
  assert.ok(Math.abs(M.localSeconds(local, { inputM: 10, outputM: 2, cachedShare: 0 }) - seconds) < 1e-6);
  assert.equal(M.kwhCost(3600, 100, 0.3), 0.03);
  assert.ok(Math.abs(M.electricityPerMillionOutput(local, 70, 0.25) - (1e6 / 72.4 / 3600) * 0.07 * 0.25) < 1e-12);
  assert.equal(M.electricityPerMillionOutput(local, 0, 0.25) > 0, true, "no watts entered: the chip's typical value is used");
  assert.equal(M.typicalWatts("Apple M4 Max"), 70);
  assert.equal(M.typicalWatts("Apple M2"), 20);
  assert.equal(M.typicalWatts("Intel"), 100);
});

test("priceRows: cheapest first, local needs an electricity price, USD is shown without an exchange rate", () => {
  const rows = [...M.cloudRows(models, community), ...M.localRows(community)];
  const u = { inputM: 5, outputM: 1, cachedShare: 0 };
  const noPrice = M.priceRows(rows, u, { currency: "EUR", watts: 0, price: 0 });
  assert.ok(noPrice.filter((p) => p.row.kind === "local").every((p) => p.cost === null && p.needsPrice));
  assert.ok(noPrice.filter((p) => p.row.kind === "cloud").every((p) => p.currency === "USD" && p.usdFallback));
  const priced = M.priceRows(rows, u, { currency: "EUR", rate: 0.9, watts: 70, price: 0.3 });
  const costs = priced.map((p) => p.cost);
  const firstNull = costs.indexOf(null);
  assert.ok(firstNull === -1 || costs.slice(firstNull).every((c) => c === null));
  assert.deepEqual(costs.slice(0, firstNull === -1 ? undefined : firstNull), [...costs.slice(0, firstNull === -1 ? undefined : firstNull)].sort((a, b) => a - b));
  const opus = priced.find((p) => p.row.id === "claude-opus-5-5");
  assert.equal(opus.currency, "EUR");
  assert.ok(Math.abs(opus.cost - (5 * 4 + 20) * 0.9) < 1e-9);
  const usdRows = M.priceRows(rows, u, { currency: "USD", watts: 70, price: 0.3 });
  assert.ok(usdRows.filter((p) => p.row.kind === "cloud").every((p) => !p.usdFallback));
});

test("electricity scenario: kWh, monthly cost and cost per million tokens", () => {
  const s = M.electricityScenario({ watts: 100, hoursPerDay: 4, price: 0.25, tokensPerSecond: 50 });
  assert.ok(Math.abs(s.kwh - 12) < 1e-9);
  assert.ok(Math.abs(s.cost - 3) < 1e-9);
  assert.ok(Math.abs(s.tokens - 50 * 3600 * 4 * 30) < 1e-6);
  assert.ok(Math.abs(s.perMillion - 3 / (s.tokens / 1e6)) < 1e-9);
  assert.equal(M.electricityScenario({ watts: 100, hoursPerDay: 4, price: null }), null, "no price, no answer");
  assert.equal(M.electricityScenario({ watts: 0, hoursPerDay: 4, price: 0.2 }), null);
  assert.equal(M.electricityScenario({ watts: 100, hoursPerDay: 4, price: 0 }).cost, 0);
});

test("quotapilot stats --json is read into monthly millions of tokens, leaving local-model tokens out", () => {
  const json = JSON.stringify({ hours: 24, total: { input: 1, cacheRead: 1, cacheWrite: 1, output: 1, reasoning: 1, total: 5 },
    providers: { claude: { input: 100000, cacheRead: 900000, cacheWrite: 0, output: 40000, reasoning: 10000, total: 1050000 }, local: { input: 5e6, cacheRead: 0, cacheWrite: 0, output: 5e6, reasoning: 0, total: 1e7 } } });
  const p = M.parseStats(json);
  assert.ok(Math.abs(p.inputM - 30) < 1e-9, "1M input per day = 30M per month");
  assert.ok(Math.abs(p.outputM - 1.5) < 1e-9);
  assert.ok(Math.abs(p.cachedShare - 0.9) < 1e-9);
  assert.equal(M.parseStats("not json"), null);
  assert.equal(M.parseStats("{}"), null);
  assert.equal(M.parseStats(JSON.stringify({ hours: 0, providers: { a: { input: 1 } } })), null);
  assert.ok(M.parseStats(JSON.stringify({ hours: 48, total: { input: 100, cacheRead: 0, cacheWrite: 0, output: 50, reasoning: 0 } })).inputM > 0, "falls back to the total");
});

test("currency defaults follow the region, with USD as the fallback", () => {
  assert.equal(M.currencyForLocale("en-US"), "USD");
  assert.equal(M.currencyForLocale("en-GB"), "GBP");
  assert.equal(M.currencyForLocale("de-DE"), "EUR");
  assert.equal(M.currencyForLocale("ja-JP"), "JPY");
  assert.equal(M.currencyForLocale("zh-TW"), "TWD");
  assert.equal(M.currencyForLocale("xx-ZZ"), "USD");
  assert.equal(M.currencyForLocale(""), "USD");
  assert.match(M.money(1234.5, "EUR", "de-DE"), /1\.234,50/);
  assert.equal(M.money(3, "ZZZZ", "en-US").startsWith("ZZZZ"), true);
});

test("English and Chinese strings have the same keys, and Chinese is Chinese", () => {
  const en = Object.keys(M.STRINGS.en).sort(), zh = Object.keys(M.STRINGS.zh).sort();
  assert.deepEqual(en, zh);
  for (const k of en) {
    const vars = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    assert.deepEqual(vars(M.STRINGS.zh[k]), vars(M.STRINGS.en[k]), `placeholders of ${k}`);
  }
  assert.match(M.STRINGS.zh.h1, /[一-鿿]/);
});

test("smartness is an empty, hidden slot: nothing stored, nothing shown", () => {
  assert.equal(M.SMARTNESS.enabled, false);
  const html = M.headerHtml("en");
  assert.match(html, /<th scope="col" data-col="smartness"[^>]*\shidden/);
  const row = M.rowHtml(M.cloudRows(models, community)[0], "en");
  assert.match(row, /<td data-col="smartness"[^>]*\shidden/);
  for (const m of models.models) for (const k of ["intelligence", "smartness", "benchmark", "score", "elo", "mmlu"]) assert.equal(k in m, false, `${m.id}.${k}`);
  // the page never fetches or embeds scores
  const js = read("assets/models-page.js") + read("assets/models-core.js");
  assert.doesNotMatch(js, /artificialanalysis|lmarena|lmsys|livebench|huggingface\.co/i);
});

function assertCspSafe(doc, name) {
  for (const m of doc.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (/\bsrc="/.test(m[1])) { assert.equal(m[2].trim(), "", `${name}: script with src has no body`); continue; }
    assert.match(m[1], /type="application\/ld\+json"/, `${name}: inline script must be JSON-LD`);
    JSON.parse(m[2]);
  }
  assert.doesNotMatch(doc, /<style[\s>]/i, name);
  assert.doesNotMatch(doc, /\son[a-z]+\s*=\s*["']/i, name);
  assert.doesNotMatch(doc, /\sstyle\s*=\s*["']/i, name);
  assert.doesNotMatch(doc, /javascript:/i, name);
}

test("generated pages exist in both languages, follow the CSP rules, link each other and are in the sitemap", () => {
  const out = mkdtempSync(join(tmpdir(), "aqw-models-"));
  try {
    execFileSync(process.execPath, [join(root, "scripts/build-pages.mjs"), out, "--base", "https://example.test/"], { stdio: "pipe" });
    const files = ["models/index.html", "models/local-llm-speed-by-mac-chip.html", "models/llm-api-price-comparison.html", "zh/models/index.html", "zh/models/local-llm-speed-by-mac-chip.html", "zh/models/llm-api-price-comparison.html"];
    const sitemap = readFileSync(join(out, "sitemap.xml"), "utf8");
    for (const f of files) {
      assert.ok(existsSync(join(out, f)), f);
      const doc = readFileSync(join(out, f), "utf8");
      assertCspSafe(doc, f);
      assert.match(doc, /<meta name="color-scheme" content="light dark">/, f);
      assert.match(doc, /rel="alternate" hreflang="(en|zh-Hant)"/, f);
      assert.match(doc, new RegExp(`<a href="(\\.\\./)+(zh/)?models/">`), `${f}: nav link`);
      const pretty = f.replace(/index\.html$/, "").replace(/\.html$/, "");
      assert.ok(sitemap.includes(`<loc>https://example.test/${pretty}</loc>`), `${f} in sitemap`);
      assert.doesNotMatch(doc, /href="(?!https?:)[^"]*\.html"/, `${f}: pretty links`);
    }
    const en = readFileSync(join(out, "models/index.html"), "utf8"), zh = readFileSync(join(out, "zh/models/index.html"), "utf8");
    assert.match(en, /<html lang="en">/);
    assert.match(zh, /<html lang="zh-Hant">/);
    assert.match(zh, /<title>[^<]*[一-鿿]/);
    assert.match(en, /<script src="\.\.\/assets\/models-core\.js"><\/script>\s*<script src="\.\.\/assets\/models-page\.js"><\/script>/);
    assert.match(zh, /<script src="\.\.\/\.\.\/assets\/models-core\.js"><\/script>/);
    // the table is real HTML with every cloud model, inside a scroll container (no horizontal page scroll on phones)
    assert.match(en, /<div class="table-scroll" tabindex="0"><table class="models rank-table" id="rankTable">/);
    for (const m of models.models) assert.ok(en.includes(`data-id="${m.id}"`), m.id);
    // interactive parts stay hidden until the script shows them
    for (const id of ["modelsTools", "calc", "elec"]) assert.match(en, new RegExp(`id="${id}" hidden`), id);
    // titles are search friendly
    for (const doc of [en, zh]) assert.ok(doc.match(/<title>([^<]*)<\/title>/)[1].length <= 70);
    // honest empty state while there is no local data (the committed community.json has none)
    const chips = readFileSync(join(out, "models/local-llm-speed-by-mac-chip.html"), "utf8");
    if (!JSON.parse(read("data/community.json")).localRuns?.rows?.length) {
      assert.match(chips, /No community measurements yet/);
      assert.match(chips, /quotapilot share --only localRuns/);
      assert.doesNotMatch(chips, /<table/);
    }
  } finally { rmSync(out, { recursive: true, force: true }); }
});

test("the speed-by-chip page lists real rows and marks preliminary ones; the price page lists every model with its source", () => {
  const pages = (lang, c) => modelsPages({ lang, root, models, community: c, base: "https://example.test/" });
  const chips = pages("en", community).find((p) => p.path.endsWith("local-llm-speed-by-mac-chip.html"));
  assert.match(chips.body, /Apple M4 Max/);
  assert.match(chips.body, /72\.4/);
  assert.match(chips.body, /Preliminary/);
  assert.match(chips.body, /≈35/);
  assert.doesNotMatch(chips.body, /No community measurements yet/);
  const empty = pages("en", emptyCommunity).find((p) => p.path.endsWith("local-llm-speed-by-mac-chip.html"));
  assert.match(empty.body, /No community measurements yet/);
  assert.doesNotMatch(empty.body, /<table/);
  const zhEmpty = pages("zh", emptyCommunity).find((p) => p.path.endsWith("local-llm-speed-by-mac-chip.html"));
  assert.match(zhEmpty.body, /目前還沒有社群量測資料/);
  const prices = pages("en", community).find((p) => p.path.endsWith("llm-api-price-comparison.html"));
  for (const m of models.models) assert.ok(prices.body.includes(m.name.replace(/&/g, "&amp;")), m.name);
  for (const s of Object.values(models.sources)) assert.ok(prices.body.includes(s.url), s.url);
  assert.ok(prices.jsonLd.some((j) => j["@type"] === "FAQPage"));
  // a local chip other than Apple's is not on the Mac page
  const other = { ...community, localRuns: { rows: [{ ...community.localRuns.rows[0], chip: "AMD" }], preliminary: [] } };
  assert.match(pages("en", other).find((p) => p.path.endsWith("local-llm-speed-by-mac-chip.html")).body, /No community measurements yet/);
});

test("the browser script reads only this site's data, sends nothing, and uses no inline handlers or eval", () => {
  const js = read("assets/models-page.js");
  assert.doesNotMatch(js, /https?:\/\//);
  assert.doesNotMatch(js, /\beval\(|new Function|XMLHttpRequest|sendBeacon|WebSocket|document\.write/);
  assert.equal((js.match(/fetch\(/g) || []).length, 1);
  assert.match(js, /"\.\.\/data\/"/);
  assert.doesNotMatch(js, /method:\s*["']POST/i);
  const core = read("assets/models-core.js");
  assert.doesNotMatch(core, /fetch\(|XMLHttpRequest|document\./);
});

test("mobile layout rules: tables scroll inside their container, fields wrap", () => {
  const css = read("assets/style.css");
  assert.match(css, /\.table-scroll \{ overflow-x: auto;/);
  assert.match(css, /\.field-grid \{ display: grid; grid-template-columns: repeat\(auto-fit, minmax\(170px, 1fr\)\)/);
  assert.match(css, /\.field input, \.field select[^{]*\{[^}]*box-sizing: border-box; width: 100%; min-width: 0/);
});

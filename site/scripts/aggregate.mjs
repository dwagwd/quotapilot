// Turns raw community reports (data/submissions/*.json) into data/community.json.
// Run: node scripts/aggregate.mjs [--now 2026-11-02T00:00:00Z] [--in dir] [--out file]
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const WINDOW_DAYS = 7;
export const MIN_SAMPLES = 3;
export const TYPES = ["speed", "rating", "quota", "event"];
export const PROVIDERS = ["chatgpt", "claude", "gemini", "grok"];
export const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"];

const quantile = (sorted, q) => {
  if (!sorted.length) return null;
  const pos = (sorted.length - 1) * q, lo = Math.floor(pos), hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
};
const round = (v, d = 1) => (v == null ? null : Math.round(v * 10 ** d) / 10 ** d);

// Drop values outside 1.5 × IQR once there are enough samples to judge.
export function trimOutliers(values) {
  const s = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (s.length < 5) return s;
  const q1 = quantile(s, 0.25), q3 = quantile(s, 0.75), iqr = q3 - q1;
  return s.filter((v) => v >= q1 - 1.5 * iqr && v <= q3 + 1.5 * iqr);
}

export function stats(values) {
  const s = trimOutliers(values);
  return { n: s.length, median: round(quantile(s, 0.5)), p25: round(quantile(s, 0.25)), p75: round(quantile(s, 0.75)) };
}

// Validate one report; returns a clean object or null.
export function clean(r, models) {
  if (!r || !TYPES.includes(r.type)) return null;
  const date = new Date(r.date);
  if (isNaN(date)) return null;
  const model = models.find((m) => m.id === r.model);
  const base = { type: r.type, date: date.toISOString(), provider: (r.type === "quota" || r.type === "event") && r.provider ? r.provider : model ? model.provider : r.provider, model: r.model || null, reporter: r.reporter || "anon" };
  if (!PROVIDERS.includes(base.provider)) return null;
  const num = (v, lo, hi) => { const n = Number(v); return Number.isFinite(n) && n >= lo && n <= hi ? n : null; };
  if (r.type === "speed") {
    const tokens = num(r.outputTokens, 50, 1e9), secs = num(r.seconds, 0.2, 31 * 86400);
    if (!model || tokens == null || secs == null) return null;
    const calls = num(r.calls, 1, 1e7) || 1;
    const effort = EFFORTS.includes(r.effort) ? r.effort : null;
    const reasoning = num(r.reasoningTokens, 0, tokens);
    return { ...base, client: String(r.client || "").slice(0, 40), tps: tokens / secs, effort, calls, perCall: tokens / calls, reasoningShare: reasoning != null ? reasoning / tokens : null };
  }
  if (r.type === "rating") {
    const score = num(r.score, 1, 10);
    if (!model || score == null) return null;
    return { ...base, score, degraded: r.degraded === true, task: String(r.task || "other").slice(0, 20) };
  }
  if (r.type === "quota") {
    const pct = num(r.percentUsed, 0.5, 100), tokens = num(r.tokensUsed, 1000, 1e10);
    if (!r.plan || !["5h", "weekly"].includes(r.window) || pct == null || tokens == null) return null;
    const est = tokens / (pct / 100);
    const price = model && model.input != null ? (r.inputShare != null ? num(r.inputShare, 0, 1) : 0.8) : null;
    const usd = price != null ? (est * price * model.input + est * (1 - price) * model.output) / 1e6 : null;
    return { ...base, plan: String(r.plan).slice(0, 30), window: r.window, estTokens: est, estUsd: usd };
  }
  if (r.type === "event") {
    if (!["hit_limit", "reset"].includes(r.kind)) return null;
    return { ...base, kind: r.kind, plan: String(r.plan || "").slice(0, 30), hourUtc: date.getUTCHours() };
  }
  return null;
}

// One report per reporter × type × model/plan × day, so one person can't flood a stat.
export function dedupe(reports) {
  const seen = new Map();
  for (const r of reports) {
    const key = [r.reporter, r.type, r.model || r.plan, r.effort || "", r.window || "", r.kind || "", r.date.slice(0, 10)].join("|");
    if (r.reporter === "anon" || !seen.has(key)) seen.set(key + (r.reporter === "anon" ? Math.random() : ""), r);
  }
  return [...seen.values()];
}

const groupBy = (arr, keyFn) => arr.reduce((m, x) => { const k = keyFn(x); (m[k] ||= []).push(x); return m; }, {});

export const MAX_PER_REPORTER_PER_DAY = 60;

export function aggregate(raw, models, now = new Date(), blocked = []) {
  const blockedSet = new Set(blocked.map((b) => String(b).toLowerCase()));
  const perDay = new Map();
  raw = raw.filter((r) => {
    if (!r || blockedSet.has(String(r.reporter || "").toLowerCase())) return false;
    const key = (r.reporter || "anon") + "|" + String(r.date || "").slice(0, 10);
    perDay.set(key, (perDay.get(key) || 0) + 1);
    return r.reporter === undefined || r.reporter === "anon" || perDay.get(key) <= MAX_PER_REPORTER_PER_DAY;
  });
  const since = new Date(now.getTime() - WINDOW_DAYS * 864e5);
  const all = dedupe(raw.map((r) => clean(r, models)).filter(Boolean));
  const recent = all.filter((r) => new Date(r.date) >= since && new Date(r.date) <= now);
  const rejected = raw.length - raw.map((r) => clean(r, models)).filter(Boolean).length;

  const speed = Object.entries(groupBy(recent.filter((r) => r.type === "speed"), (r) => r.model))
    .map(([model, rs]) => ({ model, ...stats(rs.map((r) => r.tps)), clients: [...new Set(rs.map((r) => r.client).filter(Boolean))].slice(0, 5) }))
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.median - a.median);

  // Real usage per model and reasoning effort (reports that name an effort).
  const effortUsage = Object.entries(groupBy(recent.filter((r) => r.type === "speed" && r.effort), (r) => r.model + "|" + r.effort))
    .map(([k, rs]) => {
      const [model, effort] = k.split("|");
      const share = rs.map((r) => r.reasoningShare).filter((v) => v != null);
      return { model, effort, n: rs.length, calls: rs.reduce((a, r) => a + (r.calls || 1), 0), tps: stats(rs.map((r) => r.tps)).median, perCall: Math.round(stats(rs.map((r) => r.perCall)).median),
        reasoningShare: share.length ? round(stats(share).median, 2) : null };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => a.model.localeCompare(b.model) || EFFORTS.indexOf(a.effort) - EFFORTS.indexOf(b.effort));

  const ratings = Object.entries(groupBy(recent.filter((r) => r.type === "rating"), (r) => r.model))
    .map(([model, rs]) => {
      const degradedShare = rs.filter((r) => r.degraded).length / rs.length;
      return { model, n: rs.length, avg: round(rs.reduce((a, r) => a + r.score, 0) / rs.length), degradedShare: round(degradedShare, 2), alert: rs.length >= MIN_SAMPLES && degradedShare >= 0.3 };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.avg - a.avg);

  const quota = Object.entries(groupBy(recent.filter((r) => r.type === "quota"), (r) => [r.provider, r.plan, r.window].join("|")))
    .map(([k, rs]) => {
      const [provider, plan, window] = k.split("|");
      const tok = stats(rs.map((r) => r.estTokens)), usd = stats(rs.map((r) => r.estUsd).filter((v) => v != null));
      return { provider, plan, window, n: tok.n, medianTokens: Math.round(tok.median), p25Tokens: Math.round(tok.p25), p75Tokens: Math.round(tok.p75), medianUsd: usd.n ? usd.median : null };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => a.provider.localeCompare(b.provider) || b.medianTokens - a.medianTokens);

  // Events use a 30-day window: they are rarer than other reports.
  const eventSince = new Date(now.getTime() - 30 * 864e5);
  const evs = all.filter((r) => r.type === "event" && new Date(r.date) >= eventSince && new Date(r.date) <= now);
  const byHour = {};
  for (const p of PROVIDERS) byHour[p] = Array(24).fill(0);
  evs.forEach((e) => { byHour[e.provider][e.hourUtc]++; });
  const eventCounts = Object.entries(groupBy(evs, (e) => e.provider + "|" + e.kind)).map(([k, rs]) => { const [provider, kind] = k.split("|"); return { provider, kind, n: rs.length }; });

  return {
    generated: now.toISOString(),
    windowDays: WINDOW_DAYS,
    eventWindowDays: 30,
    minSamples: MIN_SAMPLES,
    totals: { reports: recent.length, reporters: new Set(recent.map((r) => r.reporter).filter((r) => r !== "anon")).size, rejected },
    speed, effortUsage, ratings, quota,
    events: { byHourUtc: byHour, counts: eventCounts }
  };
}

// CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const arg = (name, def) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : def; };
  const root = fileURLToPath(new URL("..", import.meta.url));
  const dir = arg("--in", join(root, "data/submissions"));
  const out = arg("--out", join(root, "data/community.json"));
  const now = new Date(arg("--now", new Date().toISOString()));
  const models = JSON.parse(readFileSync(join(root, "data/models.json"), "utf8")).models;
  const raw = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".json")).flatMap((f) => {
    const v = JSON.parse(readFileSync(join(dir, f), "utf8")); return Array.isArray(v) ? v : [v];
  }) : [];
  const blockFile = join(root, "data/blocklist.json");
  const blocked = existsSync(blockFile) ? JSON.parse(readFileSync(blockFile, "utf8")).reporters || [] : [];
  const result = aggregate(raw, models, now, blocked);
  // Keep the old timestamp when nothing else changed, so the scheduled run does not commit every 6 hours.
  if (existsSync(out)) {
    const previous = JSON.parse(readFileSync(out, "utf8"));
    if (JSON.stringify({ ...previous, generated: null }) === JSON.stringify({ ...result, generated: null })) result.generated = previous.generated;
  }
  writeFileSync(out, JSON.stringify(result, null, 2) + "\n");
  console.log(`community.json: ${result.totals.reports} reports in window, ${result.speed.length} speed rows, ${result.ratings.length} rating rows, ${result.quota.length} quota rows, ${result.totals.rejected} rejected`);
}

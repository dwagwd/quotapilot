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
  const dayOf = (v) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);
  const base = { type: r.type, date: date.toISOString(), provider: (r.type === "quota" || r.type === "event") && r.provider ? r.provider : model ? model.provider : r.provider, model: r.model || null, reporter: r.reporter || "anon",
    firstSeen: dayOf(r.reporterFirstSeen), receivedDay: dayOf(r.receivedDay), ipGroup: typeof r.ipGroup === "string" && /^[0-9a-f]{8}$/.test(r.ipGroup) ? r.ipGroup : null };
  if (!PROVIDERS.includes(base.provider)) return null;
  const num = (v, lo, hi) => { const n = Number(v); return Number.isFinite(n) && n >= lo && n <= hi ? n : null; };
  if (r.type === "speed") {
    const tokens = num(r.outputTokens, 50, 1e9), secs = num(r.seconds, 0.2, 31 * 86400);
    if (!model || tokens == null || secs == null) return null;
    const calls = num(r.calls, 1, 1e7) || 1;
    const effort = EFFORTS.includes(r.effort) ? r.effort : null;
    const reasoning = num(r.reasoningTokens, 0, tokens);
    // Prompt side (QuotaPilot 0.6.3+): new input, cache reads and cache writes, as totals for the same calls.
    const inp = num(r.inputTokens, 0, 1e12), cRead = num(r.cacheReadTokens, 0, 1e12), cWrite = num(r.cacheWriteTokens, 0, 1e12);
    const prompt = inp != null && cRead != null && cWrite != null ? inp + cRead + cWrite : null;
    return { ...base, client: String(r.client || "").slice(0, 40), tps: tokens / secs, effort, calls, perCall: tokens / calls, reasoningShare: reasoning != null ? reasoning / tokens : null,
      inputPerOutput: prompt ? prompt / tokens : null, cacheHit: prompt ? cRead / prompt : null, cacheWriteShare: prompt ? cWrite / prompt : null };
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

// Reporter age. The collector stamps each report with reporterFirstSeen (the day its reporter id was first seen)
// and receivedDay (the day the collector got it). A reporter counts only once it is established:
//   - it sent a report on a later day than its first-seen day (first seen before the report's day), or
//   - it sent reports on at least two distinct days (covers a first-seen record that expired and restarted).
// Both use the collector's own days, never the client-supplied report date, which a client could backdate or
// forward-date. Established status applies to all of that reporter's reports, so a real new user's first-day
// reports start counting as soon as they report again on another day. Reports without reporterFirstSeen (older
// collector data) are counted as before, so existing published stats stay.
export function establishedReporters(reports) {
  const info = new Map();
  for (const r of reports) {
    const id = r.reporter || "anon";
    const i = info.get(id) || { legacy: false, aged: false, days: new Set() };
    const received = r.receivedDay || r.date.slice(0, 10);
    if (!r.firstSeen) i.legacy = true;
    else if (r.firstSeen < received) i.aged = true;
    i.days.add(received);
    info.set(id, i);
  }
  return new Set([...info].filter(([, i]) => i.legacy || i.aged || i.days.size >= 2).map(([id]) => id));
}

// Network diversity. ipGroup is a daily-rotating hash of the reporter's /24 (IPv4) or /48 (IPv6) network, so it
// already identifies one network on one day. Within one stats row, reporters that share an ipGroup are joined
// into one unit (transitively, union-find), and each unit counts once toward MIN_SAMPLES and gives one value, so
// many install ids sent from one network on one day weigh as one person. Reports without ipGroup (older data,
// issue reports) form their own unit per reporter, exactly as before.
export function reporterUnits(rs) {
  const parent = new Map();
  const find = (x) => { if (!parent.has(x)) parent.set(x, x); while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
  const union = (a, b) => { const ra = find(a), rb = find(b); if (ra !== rb) parent.set(ra, rb); };
  for (const r of rs) {
    const who = "p:" + (r.reporter || "anon");
    find(who);
    if (r.ipGroup) union(who, "g:" + r.ipGroup);
  }
  return Object.values(groupBy(rs, (r) => find("p:" + (r.reporter || "anon"))));
}

export function aggregate(raw, models, now = new Date(), blocked = []) {
  // The blocklist holds anonymous reporter ids (anon-…) of abusive senders.
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
  // Only established reporters feed the stats rows (see establishedReporters); totals still show every report.
  const established = establishedReporters(all);
  const counted = recent.filter((r) => established.has(r.reporter || "anon"));

  // Publication needs MIN_SAMPLES distinct people, not MIN_SAMPLES reports: each person (reporter unit, see
  // reporterUnits) contributes one value per row (the median of their own reports), and `reports` keeps the raw
  // count. Reports without a reporter id ("anon") cannot be told apart, so together they count as one reporter.
  const byReporter = reporterUnits;
  const perPerson = (rs, value) => byReporter(rs).map((mine) => {
    const v = mine.map(value).filter((x) => x != null && Number.isFinite(x)).sort((a, b) => a - b);
    return v.length ? quantile(v, 0.5) : null;
  }).filter((v) => v != null);
  const people = (rs) => byReporter(rs).length;

  const speed = Object.entries(groupBy(counted.filter((r) => r.type === "speed"),(r) => r.model))
    .map(([model, rs]) => ({ model, ...stats(perPerson(rs, (r) => r.tps)), reporters: people(rs), reports: rs.length, clients: [...new Set(rs.map((r) => r.client).filter(Boolean))].slice(0, 5) }))
    .filter((s) => s.reporters >= MIN_SAMPLES && s.n >= MIN_SAMPLES).sort((a, b) => b.median - a.median);

  // Real usage per model and reasoning effort (reports that name an effort).
  const effortUsage = Object.entries(groupBy(counted.filter((r) => r.type === "speed" && r.effort), (r) => r.model + "|" + r.effort))
    .map(([k, rs]) => {
      const [model, effort] = k.split("|");
      const share = perPerson(rs, (r) => r.reasoningShare);
      return { model, effort, n: people(rs), reports: rs.length, calls: rs.reduce((a, r) => a + (r.calls || 1), 0), tps: stats(perPerson(rs, (r) => r.tps)).median, perCall: Math.round(stats(perPerson(rs, (r) => r.perCall)).median),
        reasoningShare: share.length ? round(stats(share).median, 2) : null };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => a.model.localeCompare(b.model) || EFFORTS.indexOf(a.effort) - EFFORTS.indexOf(b.effort));

  // Token mix per model: prompt tokens per output token and the share of the prompt served from cache.
  // One value per person (their median), shown once MIN_SAMPLES people report it.
  const tokenMix = Object.entries(groupBy(counted.filter((r) => r.type === "speed" && r.inputPerOutput != null), (r) => r.model))
    .map(([model, rs]) => {
      const q = (values, p) => { const v = trimOutliers(values); return v.length ? quantile(v, p) : null; };
      const ratio = perPerson(rs, (r) => r.inputPerOutput), hit = perPerson(rs, (r) => r.cacheHit), write = perPerson(rs, (r) => r.cacheWriteShare);
      return { model, n: people(rs), reports: rs.length, inputPerOutput: round(q(ratio, 0.5), 1), inputPerOutputP25: round(q(ratio, 0.25), 1), inputPerOutputP75: round(q(ratio, 0.75), 1),
        cacheHit: round(q(hit, 0.5), 3), cacheWriteShare: round(q(write, 0.5), 3) };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.cacheHit - a.cacheHit);

  const ratings = Object.entries(groupBy(counted.filter((r) => r.type === "rating"), (r) => r.model))
    .map(([model, rs]) => {
      const scores = byReporter(rs).map((mine) => mine.reduce((a, r) => a + r.score, 0) / mine.length);
      const degraded = byReporter(rs).map((mine) => mine.filter((r) => r.degraded).length / mine.length);
      const degradedShare = degraded.reduce((a, v) => a + v, 0) / degraded.length;
      const n = scores.length;
      return { model, n, reports: rs.length, avg: round(scores.reduce((a, v) => a + v, 0) / n), degradedShare: round(degradedShare, 2), alert: n >= MIN_SAMPLES && degradedShare >= 0.3 };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.avg - a.avg);

  const quota = Object.entries(groupBy(counted.filter((r) => r.type === "quota"), (r) => [r.provider, r.plan, r.window].join("|")))
    .map(([k, rs]) => {
      const [provider, plan, window] = k.split("|");
      const tok = stats(perPerson(rs, (r) => r.estTokens)), usd = stats(perPerson(rs, (r) => r.estUsd));
      return { provider, plan, window, n: tok.n, reporters: people(rs), reports: rs.length, medianTokens: Math.round(tok.median), p25Tokens: Math.round(tok.p25), p75Tokens: Math.round(tok.p75), medianUsd: usd.n ? usd.median : null };
    })
    .filter((s) => s.reporters >= MIN_SAMPLES && s.n >= MIN_SAMPLES).sort((a, b) => a.provider.localeCompare(b.provider) || b.medianTokens - a.medianTokens);

  // Events use a 30-day window: they are rarer than other reports.
  const eventSince = new Date(now.getTime() - 30 * 864e5);
  // Like every other row, a provider's events are published only once MIN_SAMPLES established people report
  // them: with fewer, the hour-of-day chart would show one person's working hours.
  const evsAll = all.filter((r) => r.type === "event" && established.has(r.reporter || "anon") && new Date(r.date) >= eventSince && new Date(r.date) <= now);
  const evs = Object.values(groupBy(evsAll, (e) => e.provider)).filter((rs) => people(rs) >= MIN_SAMPLES).flat();
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
    speed, effortUsage, tokenMix, ratings, quota,
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

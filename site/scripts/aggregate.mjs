// Turns raw community reports (data/submissions/*.json) into data/community.json.
// Run: node scripts/aggregate.mjs [--now 2026-11-02T00:00:00Z] [--in dir] [--out file]
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { sanitize as sanitizeReport } from "../../collector/schema.js";

export const WINDOW_DAYS = 7;
export const MIN_SAMPLES = 3;
// A "feels worse" warning is a strong public claim, so it needs more people than a plain row, and at least
// MIN_SAMPLES of them must say so themselves.
export const ALERT_MIN_PEOPLE = 5;
export const TYPES = ["speed", "rating", "quota", "event", "localrun"];
export const PROVIDERS = ["chatgpt", "claude", "gemini", "grok"];
export const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
// Preliminary rows: speed and plan quota for a model or plan that 1 or 2 established people report, so the page is
// not empty while the community is small. They carry only a coarse median and the people count: no quartiles, no
// clients, no dollar figure, speed rounded to 5 tok/s and tokens to 2 significant figures, so one person's exact
// numbers are never published. Ratings, token mix, effort usage and limit events (which would show one person's
// working hours) stay behind MIN_SAMPLES.
export const PRELIM_SPEED_STEP = 5;

// Preliminary quota rows publish the plan string, and the collector accepts any short text for `plan`, so a
// row from 1 or 2 people is shown only when the plan is on this list (compared case-insensitively, trimmed).
// Built from what the app sends: ContributionReport.planName (underscores to spaces, each word capitalised)
// applied to the raw plan ids in Sources/UsageCore/PlanCatalog.swift, plus the plan names in data/plans.json.
// Plans with 3 or more people are published regardless: that is the normal row rule, not this list.
const planName = (raw) => raw.replace(/_/g, " ").split(" ").filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(" ");
const PLAN_IDS = {
  chatgpt: ["free", "go", "plus", "pro", "prolite", "pro_lite", "pro_5x", "pro_20x", "team", "business", "self_serve_business_usage_based", "enterprise", "edu", "education", "k12"],
  claude: ["free", "pro", "max", "max_5x", "max_20x", "team", "enterprise"],
  gemini: ["oauth_personal", "gemini_api_key", "vertex_ai", "compute_adc", "google_ai_pro", "google_ai_ultra", "free_tier", "standard_tier", "enterprise_tier", "legacy_tier"],
  grok: []
};
export const KNOWN_PLANS = (() => {
  const out = Object.fromEntries(PROVIDERS.map((p) => [p, new Set((PLAN_IDS[p] || []).map((id) => planName(id).toLowerCase()))]));
  try {
    const catalog = JSON.parse(readFileSync(new URL("../data/plans.json", import.meta.url), "utf8"));
    for (const prov of catalog.providers || []) {
      if (!out[prov.id]) continue;
      for (const plan of [...(prov.plans || []), ...(prov.subproducts || []).flatMap((s) => s.plans || [])]) if (plan.name) out[prov.id].add(String(plan.name).trim().toLowerCase());
    }
  } catch { /* without plans.json only the ids above count */ }
  return out;
})();
export const isKnownPlan = (provider, plan) => typeof plan === "string" && !!KNOWN_PLANS[provider]?.has(plan.trim().toLowerCase());
export const roundSig = (v, digits = 2) => {
  if (!Number.isFinite(v) || v <= 0) return null;
  const p = 10 ** (Math.floor(Math.log10(v)) - digits + 1);
  return Math.round(v / p) * p;
};

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

// Bits per weight by quantization, to tell an impossible claim (a 70B model at 8 bits "running" on 8 GB) from a real one.
const QUANT_BITS = { Q2_K: 2.7, Q3_K_S: 3.2, Q3_K_M: 3.5, Q3_K_L: 3.8, Q4_0: 4.5, Q4_1: 5, Q4_K_S: 4.6, Q4_K_M: 4.8, Q5_0: 5.5, Q5_1: 6, Q5_K_S: 5.5, Q5_K_M: 5.7, Q6_K: 6.6, Q8_0: 8.5,
  IQ2: 2.4, IQ3: 3.3, IQ4: 4.3, "2bit": 2.5, "3bit": 3.5, "4bit": 4.5, "5bit": 5.5, "6bit": 6.5, "8bit": 8.5, FP8: 8, FP16: 16, BF16: 16, MXFP4: 4.3, NVFP4: 4.3, INT4: 4.5, INT8: 8.5, AWQ: 4.5, GPTQ: 4.5 };
// Plausibility limits for local runs: the generation speed a model of this size can reach on consumer hardware, and the memory it needs.
export const localGenCap = (paramsB) => Math.min(5000, 12000 / Math.max(paramsB || 1, 1));
export const LOCAL_MIN_SAMPLES = 3;

// A local run (opt-in): re-checked with the collector's own allow-list, then against ranges that real machines reach.
function cleanLocalRun(r, base) {
  const v = sanitizeReport({ ...r, type: "localrun" });
  if (!v) return null;
  if (v.samples < LOCAL_MIN_SAMPLES) return null;
  const paramsB = v.paramsB ?? null;
  if (v.genTps != null && v.genTps > localGenCap(paramsB)) return null;
  if (paramsB != null) {
    const weightsGB = paramsB * (QUANT_BITS[v.quant] ?? 4) / 8;
    if (weightsGB > v.memGB * 1.3) return null;  // does not fit in that memory, even with some offloading
  }
  const group = [v.localModel, paramsB ?? "", v.quant || "", v.engine, v.chip, v.memGB].join("|");
  return { ...base, provider: "local", model: null, group, localModel: v.localModel, paramsB, quant: v.quant || null, engine: v.engine, engineVersion: v.engineVersion || null,
    chip: v.chip, memGB: v.memGB, genTps: v.genTps ?? null, promptTps: v.promptTps ?? null, samples: v.samples };
}

// Validate one report; returns a clean object or null.
export function clean(r, models) {
  if (!r || !TYPES.includes(r.type)) return null;
  const date = new Date(r.date);
  if (isNaN(date)) return null;
  // A report may not claim a time in the future or long before the collector received it (backdating would
  // let one sender fill old days that are already published).
  const received = typeof r.receivedDay === "string" && /^\d{4}-\d{2}-\d{2}$/.test(r.receivedDay) ? new Date(r.receivedDay + "T23:59:59Z") : null;
  if (received && (date > new Date(received.getTime() + 3600e3) || date < new Date(received.getTime() - 9 * 864e5))) return null;
  const model = models.find((m) => m.id === r.model);
  const dayOf = (v) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);
  const base = { type: r.type, date: date.toISOString(), provider: (r.type === "quota" || r.type === "event") && r.provider ? r.provider : model ? model.provider : r.provider, model: r.model || null, reporter: r.reporter || "anon",
    firstSeen: dayOf(r.reporterFirstSeen), receivedDay: dayOf(r.receivedDay), via: r.via === "site" ? "site" : r.via ? "other" : null, ipGroup: typeof r.ipGroup === "string" && /^[0-9a-f]{8}$/.test(r.ipGroup) ? r.ipGroup : null };
  if (r.type === "localrun") return cleanLocalRun(r, base);
  if (!PROVIDERS.includes(base.provider)) return null;
  const num = (v, lo, hi) => { const n = Number(v); return Number.isFinite(n) && n >= lo && n <= hi ? n : null; };
  if (r.type === "speed") {
    const tokens = num(r.outputTokens, 50, 1e9), secs = num(r.seconds, 0.2, 31 * 86400);
    if (!model || tokens == null || secs == null) return null;
    const calls = num(r.calls, 1, 1e7) || 1;
    // Plausibility, so one sender cannot drag a row with impossible numbers: speed must be in a range real
    // agents reach, and calls must look like real calls.
    const tps = tokens / secs, cap = 2000;
    if (tps < 1 || tps > cap || tokens / calls > 200000 || secs / calls > 900 || secs / calls < 0.2) return null;
    const effort = EFFORTS.includes(r.effort) ? r.effort : null;
    const reasoning = num(r.reasoningTokens, 0, tokens);
    // Prompt side (QuotaPilot 0.6.3+): new input, cache reads and cache writes, as totals for the same calls.
    const inp = num(r.inputTokens, 0, 1e12), cRead = num(r.cacheReadTokens, 0, 1e12), cWrite = num(r.cacheWriteTokens, 0, 1e12);
    let prompt = inp != null && cRead != null && cWrite != null ? inp + cRead + cWrite : null;
    if (prompt != null && (prompt / tokens > 5000 || prompt / calls > 5e6)) prompt = null;  // implausible prompt side: dropped, speed kept
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
    if (r.window === "5h" && pct < 10) return null;  // too coarse to extrapolate a 5-hour window from under 10%
    const est = tokens / (pct / 100);
    if (est > 5e10) return null;  // no plan window holds 50B tokens
    const price = model && model.input != null ? (r.inputShare != null ? num(r.inputShare, 0, 1) : 0.8) : null;
    const usd = price != null ? (est * price * model.input + est * (1 - price) * model.output) / 1e6 : null;
    return { ...base, plan: String(r.plan).slice(0, 30), window: r.window, estTokens: est, estUsd: usd };
  }
  if (r.type === "event") {
    if (!["hit_limit", "reset"].includes(r.kind)) return null;
    // From QuotaPilot 0.6.3 `date` is the hour the limit was first reached and `resetAt` the hour the window resets.
    // resetAt is kept only when it is a date within [date, date + 8 days].
    let resetAt = null;
    if (typeof r.resetAt === "string") {
      const t = new Date(r.resetAt);
      if (!isNaN(t) && t >= date && t <= new Date(date.getTime() + 8 * 864e5)) resetAt = t.toISOString();
    }
    return { ...base, kind: r.kind, plan: String(r.plan || "").slice(0, 30), hourUtc: date.getUTCHours(), resetAt };
  }
  return null;
}

// One report per reporter × type × model/plan × day, so one person can't flood a stat.
export function dedupe(reports) {
  const seen = new Map();
  for (const r of reports) {
    // A limit episode (hit_limit) is one event per reporter x provider x reset hour, however many days it lasts;
    // without resetAt the event hour stands in.
    const episode = r.type === "event" && r.kind === "hit_limit";
    const key = episode
      ? [r.reporter, "event", "hit_limit", r.provider, r.resetAt ? "reset:" + r.resetAt.slice(0, 13) : "hour:" + r.date.slice(0, 13)].join("|")
      : [r.reporter, r.type, r.model || r.plan || r.group, r.effort || "", r.window || "", r.kind || "", r.date.slice(0, 10)].join("|");
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
// The website form is a one-shot, so it can never pass the rules above. A reporter whose reports are all
// via "site" is established instead when, on each day it reported, its ipGroup was shared with no other reporter
// (a report without ipGroup cannot be checked and does not qualify).
// reporterStatus also returns `oneShot`: reporters established only by the site rule. A published row needs at
// least one unit that is not one of them (see aggregate), so three browser submissions from three networks in
// one day cannot publish a row on their own.
export function reporterStatus(reports) {
  const members = new Map();
  for (const r of reports) {
    if (!r.ipGroup) continue;
    const k = (r.receivedDay || r.date.slice(0, 10)) + "|" + r.ipGroup;
    if (!members.has(k)) members.set(k, new Set());
    members.get(k).add(r.reporter || "anon");
  }
  const info = new Map();
  for (const r of reports) {
    const id = r.reporter || "anon";
    const i = info.get(id) || { legacy: false, aged: false, days: new Set(), siteOnly: true, unique: true };
    const received = r.receivedDay || r.date.slice(0, 10);
    if (!r.firstSeen) i.legacy = true;
    else if (r.firstSeen < received) i.aged = true;
    i.days.add(received);
    if (r.via !== "site") i.siteOnly = false;
    if (!r.ipGroup || members.get(received + "|" + r.ipGroup).size > 1) i.unique = false;
    info.set(id, i);
  }
  const regular = (i) => i.legacy || i.aged || i.days.size >= 2;
  const entries = [...info];
  return {
    established: new Set(entries.filter(([, i]) => regular(i) || (i.siteOnly && i.unique)).map(([id]) => id)),
    oneShot: new Set(entries.filter(([, i]) => !regular(i) && i.siteOnly && i.unique).map(([id]) => id))
  };
}

export function establishedReporters(reports) { return reporterStatus(reports).established; }

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
  const { established, oneShot } = reporterStatus(all);
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
  // An optional metric is published only when at least MIN_SAMPLES different people supplied it. The row's own
  // people count includes people who left that metric out, so without this gate one person's value could appear
  // in a row that shows n >= 3.
  const gate = (values) => (values.length >= MIN_SAMPLES ? values : []);
  const gatedMedian = (values) => { const g = gate(values); return g.length ? stats(g).median : null; };
  // Every published row needs at least one unit with a reporter that is not a one-shot site reporter.
  const anchored = (rs) => byReporter(rs).some((unit) => unit.some((r) => !oneShot.has(r.reporter || "anon")));

  const speed = Object.entries(groupBy(counted.filter((r) => r.type === "speed"),(r) => r.model))
    .filter(([, rs]) => anchored(rs))
    .map(([model, rs]) => ({ model, ...stats(perPerson(rs, (r) => r.tps)), reporters: people(rs), reports: rs.length, clients: [...new Set(rs.map((r) => r.client).filter(Boolean))].slice(0, 5) }))
    .filter((s) => s.reporters >= MIN_SAMPLES && s.n >= MIN_SAMPLES).sort((a, b) => b.median - a.median);

  // Real usage per model and reasoning effort (reports that name an effort).
  const effortUsage = Object.entries(groupBy(counted.filter((r) => r.type === "speed" && r.effort), (r) => r.model + "|" + r.effort))
    .filter(([, rs]) => anchored(rs))
    .map(([k, rs]) => {
      const [model, effort] = k.split("|");
      const share = gatedMedian(perPerson(rs, (r) => r.reasoningShare)), perCall = gatedMedian(perPerson(rs, (r) => r.perCall));
      return { model, effort, n: people(rs), reports: rs.length, calls: rs.reduce((a, r) => a + (r.calls || 1), 0), tps: gatedMedian(perPerson(rs, (r) => r.tps)), perCall: perCall == null ? null : Math.round(perCall),
        reasoningShare: share == null ? null : round(share, 2) };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => a.model.localeCompare(b.model) || EFFORTS.indexOf(a.effort) - EFFORTS.indexOf(b.effort));

  // Token mix per model: prompt tokens per output token and the share of the prompt served from cache.
  // One value per person (their median), shown once MIN_SAMPLES people report it.
  const tokenMix = Object.entries(groupBy(counted.filter((r) => r.type === "speed" && r.inputPerOutput != null), (r) => r.model))
    .filter(([, rs]) => anchored(rs))
    .map(([model, rs]) => {
      const q = (values, p) => { const v = trimOutliers(gate(values)); return v.length ? quantile(v, p) : null; };
      const ratio = perPerson(rs, (r) => r.inputPerOutput), hit = perPerson(rs, (r) => r.cacheHit), write = perPerson(rs, (r) => r.cacheWriteShare);
      return { model, n: people(rs), reports: rs.length, inputPerOutput: round(q(ratio, 0.5), 1), inputPerOutputP25: round(q(ratio, 0.25), 1), inputPerOutputP75: round(q(ratio, 0.75), 1),
        cacheHit: round(q(hit, 0.5), 3), cacheWriteShare: round(q(write, 0.5), 3) };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.cacheHit - a.cacheHit);

  const ratings = Object.entries(groupBy(counted.filter((r) => r.type === "rating"), (r) => r.model))
    .filter(([, rs]) => anchored(rs))
    .map(([model, rs]) => {
      const scores = byReporter(rs).map((mine) => mine.reduce((a, r) => a + r.score, 0) / mine.length);
      const degraded = byReporter(rs).map((mine) => mine.filter((r) => r.degraded).length / mine.length);
      const degradedShare = degraded.reduce((a, v) => a + v, 0) / degraded.length;
      const n = scores.length;
      return { model, n, reports: rs.length, avg: round(scores.reduce((a, v) => a + v, 0) / n), degradedShare: round(degradedShare, 2), alert: n >= ALERT_MIN_PEOPLE && degraded.filter((v) => v > 0).length >= MIN_SAMPLES && degradedShare >= 0.3 };
    })
    .filter((s) => s.n >= MIN_SAMPLES).sort((a, b) => b.avg - a.avg);

  const quota = Object.entries(groupBy(counted.filter((r) => r.type === "quota"), (r) => [r.provider, r.plan, r.window].join("|")))
    .filter(([, rs]) => anchored(rs))
    .map(([k, rs]) => {
      const [provider, plan, window] = k.split("|");
      const tok = stats(perPerson(rs, (r) => r.estTokens)), usd = stats(perPerson(rs, (r) => r.estUsd));
      return { provider, plan, window, n: tok.n, reporters: people(rs), reports: rs.length, medianTokens: Math.round(tok.median), p25Tokens: Math.round(tok.p25), p75Tokens: Math.round(tok.p75), medianUsd: usd.n >= MIN_SAMPLES ? usd.median : null, lowerBound: true };
    })
    .filter((s) => s.reporters >= MIN_SAMPLES && s.n >= MIN_SAMPLES).sort((a, b) => a.provider.localeCompare(b.provider) || b.medianTokens - a.medianTokens);

  // Preliminary rows (see PRELIM_SPEED_STEP): 1 to MIN_SAMPLES - 1 established people, never a one-shot site sender
  // alone. The value is the median of each person's own median, the same statistic as a published row.
  const preliminarySpeed = Object.entries(groupBy(counted.filter((r) => r.type === "speed"), (r) => r.model))
    .filter(([model, rs]) => anchored(rs) && !speed.some((s) => s.model === model))
    .map(([model, rs]) => {
      const values = perPerson(rs, (r) => r.tps).sort((a, b) => a - b);
      const median = quantile(values, 0.5);
      return { model, n: values.length, median: median == null ? null : Math.max(PRELIM_SPEED_STEP, Math.round(median / PRELIM_SPEED_STEP) * PRELIM_SPEED_STEP) };
    })
    .filter((s) => s.median != null && s.n >= 1 && s.n < MIN_SAMPLES).sort((a, b) => b.median - a.median);
  const preliminaryQuota = Object.entries(groupBy(counted.filter((r) => r.type === "quota"), (r) => [r.provider, r.plan, r.window].join("|")))
    .filter(([k, rs]) => anchored(rs) && !quota.some((q) => [q.provider, q.plan, q.window].join("|") === k))
    .map(([k, rs]) => {
      const [provider, plan, window] = k.split("|");
      const values = perPerson(rs, (r) => r.estTokens).sort((a, b) => a - b);
      return { provider, plan, window, n: values.length, medianTokens: roundSig(quantile(values, 0.5)), lowerBound: true };
    })
    .filter((q) => q.medianTokens != null && q.n >= 1 && q.n < MIN_SAMPLES && isKnownPlan(q.provider, q.plan)).sort((a, b) => a.provider.localeCompare(b.provider) || b.medianTokens - a.medianTokens);

  // Local models by engine, chip and memory tier (opt-in reports). Same rules as speed rows: 3 established people for a published row,
  // 1 or 2 for a coarse preliminary one (generation speed to the nearest 5 tok/s, no quartiles, no prompt speed, no sample counts).
  const localGroups = Object.entries(groupBy(counted.filter((r) => r.type === "localrun"), (r) => r.group)).filter(([, rs]) => anchored(rs));
  const localIdentity = (r) => ({ model: r.localModel, paramsB: r.paramsB, quant: r.quant, engine: r.engine, chip: r.chip, memGB: r.memGB });
  const localRows = localGroups.map(([, rs]) => {
    const gen = stats(perPerson(rs, (r) => r.genTps)), prompt = gatedMedian(perPerson(rs, (r) => r.promptTps));
    return { ...localIdentity(rs[0]), n: people(rs), reports: rs.length, samples: rs.reduce((a, r) => a + r.samples, 0),
      genTps: gen.n >= MIN_SAMPLES ? gen.median : null, genP25: gen.n >= MIN_SAMPLES ? gen.p25 : null, genP75: gen.n >= MIN_SAMPLES ? gen.p75 : null, promptTps: prompt };
  }).filter((x) => x.n >= MIN_SAMPLES && (x.genTps != null || x.promptTps != null))
    .sort((a, b) => a.model.localeCompare(b.model) || (b.genTps ?? 0) - (a.genTps ?? 0));
  const localKey = (x) => [x.model, x.paramsB ?? "", x.quant || "", x.engine, x.chip, x.memGB].join("|");
  const localPrelim = localGroups.filter(([k]) => !localRows.some((x) => localKey(x) === k)).map(([, rs]) => {
    const values = perPerson(rs, (r) => r.genTps).sort((a, b) => a - b), median = quantile(values, 0.5);
    return { ...localIdentity(rs[0]), n: values.length, genTps: median == null ? null : Math.max(PRELIM_SPEED_STEP, Math.round(median / PRELIM_SPEED_STEP) * PRELIM_SPEED_STEP) };
  }).filter((x) => x.genTps != null && x.n >= 1 && x.n < MIN_SAMPLES).sort((a, b) => a.model.localeCompare(b.model) || b.genTps - a.genTps);

  // Events use a 30-day window: they are rarer than other reports.
  const eventSince = new Date(now.getTime() - 30 * 864e5);
  // Like every other row, a provider's events are published only once MIN_SAMPLES established people report
  // them: with fewer, the hour-of-day chart would show one person's working hours.
  const evsAll = all.filter((r) => r.type === "event" && established.has(r.reporter || "anon") && new Date(r.date) >= eventSince && new Date(r.date) <= now);
  const evs = Object.values(groupBy(evsAll, (e) => e.provider)).filter((rs) => people(rs) >= MIN_SAMPLES && anchored(rs)).flat();
  const byHour = {};
  for (const p of PROVIDERS) byHour[p] = Array(24).fill(0);
  evs.forEach((e) => { byHour[e.provider][e.hourUtc]++; });
  const eventCounts = Object.entries(groupBy(evs, (e) => e.provider + "|" + e.kind)).map(([k, rs]) => { const [provider, kind] = k.split("|"); return { provider, kind, n: people(rs) }; });

  return {
    generated: now.toISOString(),
    windowDays: WINDOW_DAYS,
    eventWindowDays: 30,
    minSamples: MIN_SAMPLES,
    totals: { reports: recent.length, reporters: new Set(recent.map((r) => r.reporter).filter((r) => r !== "anon")).size, established: reporterUnits(counted).length, rejected },
    speed, effortUsage, tokenMix, ratings, quota,
    preliminary: { speed: preliminarySpeed, quota: preliminaryQuota },
    localRuns: { rows: localRows, preliminary: localPrelim },
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
  console.log(`community.json: ${result.totals.reports} reports in window, ${result.speed.length} speed rows, ${result.ratings.length} rating rows, ${result.quota.length} quota rows, ${result.preliminary.speed.length + result.preliminary.quota.length} preliminary rows, ${result.totals.rejected} rejected`);
}

// The one list of what a shared report may contain, used by the collector.
// Data minimisation: every field is something the public statistics use, text fields only accept known
// values or short id-like strings (so nobody can store names, prompts or other free text), numbers must be
// in range, and times are cut to the hour. Anything else is dropped before a report is saved.

export const TYPES = ["speed", "rating", "quota", "event"];
const enumOf = (...values) => (v) => (values.includes(v) ? v : undefined);
const pattern = (re) => (v) => (typeof v === "string" && re.test(v) ? v : undefined);
const range = (lo, hi) => (v) => (typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : undefined);
const tokens = range(0, 1e12);

export const RULES = {
  type: enumOf(...TYPES),
  // Public model families only (the same list as ContributionReport.publicModelPrefixes in the app): a private
  // deployment or locally named model, which could carry a company or project name, is never stored.
  model: pattern(/^(?:(?:gpt|codex|claude|gemini|grok|deepseek|kimi|glm|qwen)-|o[0-9])[a-z0-9.-]{0,56}$/),
  provider: enumOf("chatgpt", "claude", "gemini", "grok"),
  plan: pattern(/^[A-Za-z0-9][A-Za-z0-9 ().+-]{0,29}$/),
  window: enumOf("5h", "weekly"),
  kind: enumOf("hit_limit", "reset"),
  effort: enumOf("minimal", "low", "medium", "high", "xhigh", "max", "ultra"),
  client: enumOf("Codex", "Claude Code", "Gemini CLI", "Grok CLI", "CLI", "Desktop", "API", "Web", "Other"),
  task: enumOf("coding", "chat", "writing", "research", "other"),
  via: enumOf("quotapilot", "site"),
  outputTokens: tokens, reasoningTokens: tokens, inputTokens: tokens, cacheReadTokens: tokens, cacheWriteTokens: tokens,
  seconds: range(0, 31 * 86400), calls: range(0, 1e7), score: range(1, 10),
  percentUsed: range(0, 100), tokensUsed: tokens, inputShare: range(0, 1),
  degraded: (v) => (typeof v === "boolean" ? v : undefined)
};

/** Report time cut to the hour (ISO, UTC), or undefined when it is not a date. */
export function hourOf(value) {
  const t = Date.parse(value);
  if (!Number.isFinite(t)) return undefined;
  return new Date(Math.floor(t / 3600e3) * 3600e3).toISOString().replace(".000Z", "Z");
}

export function sanitize(report) {
  if (!report || typeof report !== "object" || Array.isArray(report)) return null;
  const out = {};
  for (const [key, check] of Object.entries(RULES)) {
    const v = check(report[key]);
    if (v !== undefined) out[key] = v;
  }
  const date = hourOf(report.date);
  if (date) out.date = date;
  // Events may say when the quota window resets; cut to the hour like date.
  const resetAt = typeof report.resetAt === "string" ? hourOf(report.resetAt) : undefined;
  if (resetAt) out.resetAt = resetAt;
  return out.type ? out : null;
}

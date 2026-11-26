// The one list of what a shared report may contain, used by the collector.
// Data minimisation: every field is something the public statistics use, text fields only accept known
// values or short id-like strings, numbers must be in range, and times are cut to the hour. `plan` is the one
// short free-form field (letters, digits, spaces and ().+-, at most 30 characters): the aggregation publishes
// it only when 3 people sent the same name, and rows from 1-2 people only for plan names on a fixed list.
// Anything else is dropped before a report is saved.

export const TYPES = ["speed", "rating", "quota", "event", "localrun"];
const enumOf = (...values) => (v) => (values.includes(v) ? v : undefined);
const pattern = (re) => (v) => (typeof v === "string" && re.test(v) ? v : undefined);
const range = (lo, hi) => (v) => (typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : undefined);
const tokens = range(0, 1e12);
const integerIn = (lo, hi) => (v) => (Number.isInteger(v) && v >= lo && v <= hi ? v : undefined);

// Local runs (opt-in sharing of local model speed with a coarse description of the computer). Public open-weight families,
// quantizations, engines, chips and memory sizes come from fixed lists, so nothing free-form is stored. The app applies the
// same lists first (LocalModelName and LocalEngineName in Sources/UsageCore/LocalRuns.swift; a test compares them).
export const LOCAL_FAMILIES = ["llama", "codellama", "mistral", "mixtral", "ministral", "magistral", "devstral", "codestral", "gemma", "phi", "qwen", "qwq",
  "deepseek", "glm", "kimi", "granite", "olmo", "smollm", "nemotron", "minimax", "yi", "internlm", "command", "aya", "starcoder", "hermes", "falcon", "exaone", "solar", "gpt-oss"];
export const LOCAL_QUANTS = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M", "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
  "IQ2", "IQ3", "IQ4", "2bit", "3bit", "4bit", "5bit", "6bit", "8bit", "FP8", "FP16", "BF16", "MXFP4", "NVFP4", "INT4", "INT8", "AWQ", "GPTQ"];
export const LOCAL_ENGINES = ["ollama", "lmstudio", "llamacpp", "omlx", "strata", "mlx", "vllm", "other"];
export const MEMORY_TIERS = [8, 16, 24, 32, 48, 64, 96, 128, 192, 256];
export const GPU_CORE_BUCKETS = [10, 20, 40, 80];
// Apple silicon by name; every other computer only by vendor class.
const CHIP = /^(?:Apple M[1-9][0-9]?(?: Pro| Max| Ultra)?|Intel|AMD|Qualcomm|Other)$/;

export const RULES = {
  type: enumOf(...TYPES),
  localModel: pattern(new RegExp("^(?:" + LOCAL_FAMILIES.join("|") + ")[a-z0-9-]{0,44}$")),
  paramsB: range(0.05, 2000),
  quant: enumOf(...LOCAL_QUANTS),
  engine: enumOf(...LOCAL_ENGINES),
  // Coarse engine version: major.minor, or a llama.cpp build number (b4567).
  engineVersion: pattern(/^(?:[0-9]{1,4}\.[0-9]{1,3}|b[0-9]{1,6})$/),
  chip: pattern(CHIP),
  memGB: enumOf(...MEMORY_TIERS),
  gpuCores: enumOf(...GPU_CORE_BUCKETS),
  os: enumOf("macos", "linux", "windows", "other"),
  osMajor: integerIn(0, 99),
  genTps: range(0.1, 5000), promptTps: range(1, 200000), samples: range(1, 1e7),
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
  if (out.type === "localrun") {
    // A local run is only useful, and only stored, with its full identity and at least one speed.
    const need = ["localModel", "engine", "chip", "memGB", "os", "samples"];
    if (need.some((k) => out[k] === undefined) || (out.genTps === undefined && out.promptTps === undefined)) return null;
    // Fields that mean nothing for other report types stay out of them, and the other way round.
  } else {
    for (const k of ["localModel", "paramsB", "quant", "engine", "engineVersion", "chip", "memGB", "gpuCores", "os", "osMajor", "genTps", "promptTps", "samples"]) delete out[k];
  }
  return out.type ? out : null;
}

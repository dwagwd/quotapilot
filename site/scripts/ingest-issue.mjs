// Used by the GitHub Action: pulls the JSON block out of a "data-report" issue
// and saves it as data/submissions/issue-<number>.json with the author attached.
// Usage: node scripts/ingest-issue.mjs <event.json>
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Only these fields are kept; everything else in a report is dropped before it is saved.
const FIELDS = {
  type: "string", model: "string", provider: "string", plan: "string", window: "string", kind: "string", effort: "string",
  client: "string", task: "string", via: "string", date: "string",
  outputTokens: "number", reasoningTokens: "number", seconds: "number", calls: "number", score: "number",
  percentUsed: "number", tokensUsed: "number", inputShare: "number", degraded: "boolean"
};
const MAX_BODY = 20000;

export function sanitize(report) {
  if (!report || typeof report !== "object" || Array.isArray(report)) return null;
  const out = {};
  for (const [key, kind] of Object.entries(FIELDS)) {
    const v = report[key];
    if (typeof v !== kind) continue;
    if (kind === "number" && !Number.isFinite(v)) continue;
    // Plain text only: no control characters, no markup, at most 60 characters.
    out[key] = kind === "string" ? v.replace(/[\u0000-\u001f\u007f<>"'`]/g, "").slice(0, 60) : v;
  }
  return out.type ? out : null;
}

export function parseIssue(issue) {
  if ((issue.body || "").length > MAX_BODY) return { error: "The issue body is too long." };
  const m = /```json\s*([\s\S]*?)```/.exec(issue.body || "");
  if (!m) return { error: "No ```json block found in the issue body." };
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { error: "The JSON block could not be parsed: " + e.message }; }
  const login = issue.user && /^[A-Za-z0-9-]{1,39}$/.test(issue.user.login || "") ? issue.user.login : "anon";
  const list = (Array.isArray(data) ? data : [data]).slice(0, 50).map(sanitize).filter(Boolean).map((r) => ({
    ...r,
    reporter: login,
    date: r.date || issue.created_at
  }));
  if (!list.length) return { error: "No valid reports in the JSON block." };
  return { reports: list };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const event = JSON.parse(readFileSync(process.argv[2], "utf8"));
  const issue = event.issue;
  const result = parseIssue(issue);
  if (result.error) { console.error(result.error); process.exit(2); }
  const dir = join(fileURLToPath(new URL("..", import.meta.url)), "data/submissions");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `issue-${issue.number}.json`), JSON.stringify(result.reports, null, 2) + "\n");
  console.log(`saved ${result.reports.length} report(s) from issue #${issue.number}`);
}

// Used by the GitHub Action: pulls the JSON block out of a "data-report" issue
// and saves it as data/submissions/issue-<number>.json with a hashed author id (the stored files are public,
// so the GitHub login itself is not written; the hash still lets one person count once).
// Usage: node scripts/ingest-issue.mjs <event.json>
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { sanitize } from "../../collector/schema.js";
export { sanitize };

export const githubReporterId = (login) => "gh-" + createHash("sha256").update("github:" + String(login).toLowerCase()).digest("hex").slice(0, 16);

const MAX_BODY = 20000;


export function parseIssue(issue) {
  if ((issue.body || "").length > MAX_BODY) return { error: "The issue body is too long." };
  const m = /```json\s*([\s\S]*?)```/.exec(issue.body || "");
  if (!m) return { error: "No ```json block found in the issue body." };
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { error: "The JSON block could not be parsed: " + e.message }; }
  const login = issue.user && /^[A-Za-z0-9-]{1,39}$/.test(issue.user.login || "") ? issue.user.login : "anon";
  const list = (Array.isArray(data) ? data : [data]).slice(0, 50).map(sanitize).filter(Boolean).map((r) => ({
    ...r,
    reporter: login === "anon" ? "anon" : githubReporterId(login),
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

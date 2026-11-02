// Used by the GitHub Action: pulls the JSON block out of a "data-report" issue
// and saves it as data/submissions/issue-<number>.json with the author attached.
// Usage: node scripts/ingest-issue.mjs <event.json>
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export function parseIssue(issue) {
  const m = /```json\s*([\s\S]*?)```/.exec(issue.body || "");
  if (!m) return { error: "No ```json block found in the issue body." };
  let data;
  try { data = JSON.parse(m[1]); } catch (e) { return { error: "The JSON block could not be parsed: " + e.message }; }
  const list = (Array.isArray(data) ? data : [data]).slice(0, 20).map((r) => ({
    ...r,
    reporter: issue.user && issue.user.login ? issue.user.login : "anon",
    date: r.date || issue.created_at
  }));
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

// Turns new entries in the reset ledger and change log into X posts for the AI Quota Watch account.
//
//   node scripts/x-post.mjs                 preview what would be posted (default, sends nothing)
//   node scripts/x-post.mjs --send          post the pending items, oldest first, then remember them
//   node scripts/x-post.mjs --mark-seen     remember everything currently pending without posting
//   node scripts/x-post.mjs --pinned        print the suggested pinned post
//
// Credentials (only needed for --send), from the environment or the macOS keychain item of the same name:
//   AQW_X_API_KEY, AQW_X_API_SECRET, AQW_X_ACCESS_TOKEN, AQW_X_ACCESS_SECRET  (OAuth 1.0a user context)
// State: $AQW_X_STATE, default ~/Library/Application Support/AIQuotaWatch/x-posted.json
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { createHmac, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const SITE = "https://aiquotawatch.pages.dev/";
const URL_LEN = 23; // X counts every link as 23 characters
const LIMIT = 280;
const MAX_PER_RUN = 3; // never burst more than this; the rest waits for the next run
const FRESH_DAYS = 3; // older items are history, not news: they are marked seen instead of posted

const PRODUCT = { chatgpt: "ChatGPT", claude: "Claude", gemini: "Gemini", grok: "Grok" };

// X length: links count 23, CJK and other wide characters count 2.
export function xLength(text) {
  let n = 0;
  for (const part of text.split(/(https?:\/\/\S+)/)) {
    if (/^https?:\/\//.test(part)) { n += URL_LEN; continue; }
    for (const ch of part) n += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦\u{1f300}-\u{1faff}]/u.test(ch) ? 2 : 1;
  }
  return n;
}

// X bills a post that contains a link ~13x a plain one ($0.20 vs $0.015). AQW_X_LINKS=0 drops every link
// (sources and site) and points readers to the profile link instead.
export const linksOn = () => process.env.AQW_X_LINKS !== "0";
const stripLinks = (s) => s.replace(/\s*https?:\/\/\S+/g, "").replace(/(Source|Sources|Reported, not confirmed):?\s*$/gm, "").replace(/\n{2,}/g, "\n").trim();

function fit(head, body, tail) {
  if (!linksOn()) { body = stripLinks(body); tail = "Full tracker: link in bio"; }
  let b = body;
  while (b && xLength([head, b, tail].filter(Boolean).join("\n\n")) > LIMIT) b = b.slice(0, -2).replace(/\s+\S*$/, "") + "…";
  return [head, b, tail].filter(Boolean).join("\n\n");
}

export const resetId = (r) => `reset:${r.at}`;
export const changeId = (c) => `change:${c.date}:${c.provider}:${c.text.en.slice(0, 40)}`;

export function resetPost(r) {
  const kind = r.kind === "full" ? "Usage limits reset" : "Banked reset card released";
  const when = r.at.slice(0, 16).replace("T", " ") + " UTC";
  const conf = r.confidence === "official" ? "Source: vendor post" : "Source: trackers, not confirmed by the vendor";
  return fit(`${r.product}: ${kind} (${when})`, `${r.text.en}\n${conf} ${r.source}`, `Every reset so far: ${SITE}#resets`);
}

export function changePost(c) {
  const arrow = c.direction === "up" ? "More for users" : c.direction === "down" ? "Less or pricier" : "Change";
  const head = `${PRODUCT[c.provider] || c.provider} ${c.kind === "price" ? "price" : "limit"} change${c.upcoming ? `, starts ${c.date}` : ` (${c.date})`}: ${arrow}`;
  const conf = c.confidence === "official" ? "Source:" : "Reported, not confirmed:";
  return fit(head, `${c.text.en}\n${conf} ${c.source}`, `All changes: ${SITE}#changes`);
}

export function pinnedPost() {
  if (!linksOn()) return fit("AI Quota Watch tracks how much ChatGPT, Claude, Gemini and Grok plans actually give you.",
    "Alerts here when usage limits reset or plan prices change, each checked against the vendor's own post or page. ", "");
  return fit("AI Quota Watch tracks how much ChatGPT, Claude, Gemini and Grok plans actually give you.",
    "Plan limits, API cost for your own workload, every Codex reset and model speed, each number with its source and the date we checked it. Free, no account.",
    SITE);
}

// Pending = not seen before and recent enough to be news, oldest first.
export function pending(resets, changes, seen, now = new Date()) {
  const fresh = (iso) => now - new Date(iso) <= FRESH_DAYS * 864e5;
  const items = [
    ...resets.resets.map((r) => ({ id: resetId(r), at: r.at, text: resetPost(r), fresh: fresh(r.at) })),
    ...changes.changes.map((c) => ({ id: changeId(c), at: c.date + "T00:00:00Z", text: changePost(c), fresh: c.upcoming ? new Date(c.date) > now : fresh(c.date + "T00:00:00Z") }))
  ].filter((i) => !seen.has(i.id)).sort((a, b) => a.at.localeCompare(b.at));
  return { post: items.filter((i) => i.fresh).slice(0, MAX_PER_RUN), stale: items.filter((i) => !i.fresh) };
}

// ---------- OAuth 1.0a signing for POST /2/tweets ----------
const pct = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
// extra = query/form parameters that are part of the signature (none for the JSON body of /2/tweets).
export function oauthHeader(method, url, creds, nonce = randomBytes(16).toString("hex"), ts = Math.floor(Date.now() / 1000), extra = {}) {
  const p = { oauth_consumer_key: creds.key, oauth_nonce: nonce, oauth_signature_method: "HMAC-SHA1", oauth_timestamp: String(ts), oauth_token: creds.token, oauth_version: "1.0" };
  const all = { ...extra, ...p };
  const base = [method, pct(url), pct(Object.keys(all).map((k) => [pct(k), pct(all[k])]).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : 1)).map(([k, v]) => `${k}=${v}`).join("&"))].join("&");
  p.oauth_signature = createHmac("sha1", `${pct(creds.secret)}&${pct(creds.tokenSecret)}`).update(base).digest("base64");
  return "OAuth " + Object.keys(p).sort().map((k) => `${pct(k)}="${pct(p[k])}"`).join(", ");
}

function secret(name) {
  if (process.env[name]) return process.env[name];
  try { return execFileSync("security", ["find-generic-password", "-s", name, "-w"], { encoding: "utf8" }).trim(); } catch { return null; }
}

async function send(text, creds) {
  const url = "https://api.x.com/2/tweets";
  const res = await fetch(url, { method: "POST", headers: { Authorization: oauthHeader("POST", url, creds), "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`X API ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  return body.data?.id;
}

async function main() {
  const args = new Set(process.argv.slice(2));
  if (args.has("--pinned")) { console.log(pinnedPost()); return; }
  const here = dirname(fileURLToPath(import.meta.url));
  const load = (f) => JSON.parse(readFileSync(join(here, "../data", f), "utf8"));
  const statePath = process.env.AQW_X_STATE || join(homedir(), "Library/Application Support/AIQuotaWatch/x-posted.json");
  const seen = new Set(existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")).seen : []);
  const save = () => { mkdirSync(dirname(statePath), { recursive: true }); writeFileSync(statePath, JSON.stringify({ seen: [...seen].sort() }, null, 2) + "\n"); };
  const { post, stale } = pending(load("resets.json"), load("changes.json"), seen);

  if (args.has("--mark-seen")) { [...post, ...stale].forEach((i) => seen.add(i.id)); save(); console.log(`Marked ${post.length + stale.length} items as seen.`); return; }
  if (!args.has("--send")) {
    console.log(`${linksOn() ? "Links on" : "Links off (AQW_X_LINKS=0)"}. ${post.length} to post, ${stale.length} older items will be marked seen without posting.\n`);
    post.forEach((i) => console.log(`--- ${i.id} (${xLength(i.text)}/280)\n${i.text}\n`));
    return;
  }
  const creds = { key: secret("AQW_X_API_KEY"), secret: secret("AQW_X_API_SECRET"), token: secret("AQW_X_ACCESS_TOKEN"), tokenSecret: secret("AQW_X_ACCESS_SECRET") };
  if (Object.values(creds).some((v) => !v)) { console.error("Missing X credentials (AQW_X_API_KEY, AQW_X_API_SECRET, AQW_X_ACCESS_TOKEN, AQW_X_ACCESS_SECRET)."); process.exit(2); }
  stale.forEach((i) => seen.add(i.id));
  for (const i of post) {
    const id = await send(i.text, creds);
    seen.add(i.id); save();
    console.log(`posted ${i.id} -> https://x.com/i/status/${id}`);
  }
  save();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.message); process.exit(1); });

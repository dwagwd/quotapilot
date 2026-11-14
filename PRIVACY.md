# Privacy and data handling

Last updated: 2026-11-14.

QuotaPilot runs on your Mac and has no account or server of its own for the app. This page lists what it reads, what leaves the computer and when, and what it stores. The defaults below are for version 0.6.6 and later; earlier 0.6 versions had the two connection choices below turned on without asking.

## Who runs this and how to reach us

QuotaPilot and the AI Quota Watch website are run by the QuotaPilot maintainers, an open-source project hosted at [github.com/dwagwd/quotapilot](https://github.com/dwagwd/quotapilot). For a privacy question or request, [send a private report](https://github.com/dwagwd/quotapilot/security/advisories/new) (visible only to the maintainers) or open an issue without personal details. You do not need to contact anyone to delete what you shared: see "Deleting what you shared" below.

- **Where data is processed:** the website and the anonymous collector run on Cloudflare (Pages, D1; reports sent before 2026-11-14 stay in Workers KV until they expire), which stores and serves data from its global network, including outside your country. Cloudflare handles connections under [its own privacy policy](https://www.cloudflare.com/privacypolicy/).
- **Why we process it:** shared reports are processed only because you chose to send them (you can withdraw by deleting them); cookie-free visit counts are kept to know whether the site is used and to protect the free service from overload.
- **Your choices:** see, before sending, exactly what would be sent; send nothing; delete everything a computer or browser sent. Hashed ids and network hashes are pseudonymous data, so these rights apply to them too.
- **Children:** the app and site are tools for software developers and are not directed at children.
- **Changes:** this file's history in the repository shows every change; a change to what leaves your computer is also listed in `CHANGELOG.md`.

## What the app reads

- **Codex:** it asks the local Codex App Server for account identity, quota windows and the cumulative account token counter. Codex may make authenticated requests to OpenAI to answer. Codex's own policies apply.
- **Claude Code plan usage (off until you turn it on at first launch):** it reads Claude Code's stored login (the `Claude Code-credentials` keychain item through `/usr/bin/security`, or `~/.claude/.credentials.json`) and sends that token only to `https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code itself uses. The token is kept in memory and never written to disk.
- **Local agent logs (token breakdown, on by default):** it reads `~/.codex/sessions` and `~/.claude/projects` JSONL files and keeps only token counts, timestamps, model names, a provider name and a de-duplication key. Prompts, replies, tool output and file contents are not stored or sent.
- **Automatic connection (off until you turn it on at first launch):** it may edit `~/.claude/settings.json` or `~/.gemini/antigravity-cli/settings.json` to add the status-line bridge (see the last section).

The first launch asks about the last two; **Connections and privacy…** in the menu bar changes them later. The Claude plan usage request goes to the endpoint Claude Code itself uses, which Anthropic has not published for other tools and may change or restrict. The `quotapilot` command-line tool reads the same login when you run `quotapilot status`, `watch` or `route`.

It never starts model turns on its own unless you turn on **Auto-continue**, and it never redeems reset credits.

## What leaves the computer

- **Update checks (on by default):** once a day the app reads the repository's version tags from `api.github.com`, without account data. Builds made by Homebrew or from source have no Developer ID team, so they only read version tags and tell you to run `brew upgrade quotapilot` when a newer version exists; nothing is downloaded. The download-and-verify path runs only in a build signed with a Developer ID team, and no such build is published. Turning off **Check for updates automatically** stops the check.
- **Claude and Codex usage requests:** described above; they go only to Anthropic and (through Codex) OpenAI.
- **Anonymous sharing:** only if you run `quotapilot share` or turn on **Share anonymous stats daily**. See below.
- Nothing else: no telemetry or analytics service.

## Anonymous sharing (opt-in)

Nothing is shared unless you run `quotapilot share` and confirm, or turn on **Share anonymous stats daily** (off by default). `quotapilot share --json` only prints what would be sent.

- **Default destination: the AI Quota Watch collector** (`collector/`, served at `https://aiquotawatch.pages.dev/api`). No GitHub account is used. The request carries a random id created on this computer (`install-id` in the data folder); the collector stores only a keyed hash of it, never the id itself or your IP address, and deletes reports after 31 days. The daily option uses the same anonymous path.
- **Anonymous means pseudonymous:** the random install id is a stable pseudonym for this computer (the collector keeps only a keyed hash of it), so the collector can tell that two reports came from the same computer and can delete them on request, but it cannot tell who you are. Do not share the `install-id` file: whoever has it can send or delete reports as you. It is stored readable by you only.
- **No named sharing:** reports are never filed as GitHub issues or linked to any account; the anonymous collector is the only destination.
- **Contents:** model ids, reasoning effort labels, plan names, totals per model and effort (output and reasoning tokens, new input tokens, tokens read from and written to the prompt cache, call count and call time), quota percentage and tokens used per 5-hour or weekly window, and whether a limit was reached. Limit events carry the hour QuotaPilot first saw the limit reached (rounded to the hour) and the reset hour (also rounded to the hour), not the time of sharing. Reports can cover Codex, Claude Code, Gemini CLI and Grok CLI. They contain no prompts, file paths, project names, account ids or credentials.
- **Only public model names:** a report names a model only when it belongs to a public family (GPT, Codex, Claude, Gemini, Grok, DeepSeek, Kimi, GLM, Qwen). A private deployment or a model you named yourself is left out on your computer, and the collector refuses it as well.
- **A plain connection:** the request carries the report and the random id, a fixed `QuotaPilot` user agent and nothing else: no cookies, no system version, no interface language.
- **Only what the statistics need:** the collector keeps a fixed list of fields (`collector/schema.js`). Text fields accept only known values (plan names, model ids, effort and app labels), never free text; numbers must be in range; times are cut to the hour. Anything else in a report is dropped before it is stored.
- **What becomes public:** only aggregates. A model, plan or provider row (including the hour-of-day chart of limit events) appears only once at least 3 different, established people report it, each person counts once (the median of their own reports), and reporters sending from the same network on the same day count as one. Raw reports are never published. An optional figure inside a row (for example the reasoning share, the estimated dollar value or the cache share) is published only when at least 3 different people supplied that figure itself.
- **Deleting what you shared:** `quotapilot share --forget`, the menu bar's **Delete my shared stats…**, or **Delete everything this browser sent** on the website asks the collector to delete every report from that computer or browser at once (daily sharing turns off). Public stats drop them at the next rebuild, within 6 hours. Otherwise reports expire after 31 days. Deleting also turns off daily sharing (in the menu bar app and in the CLI); a script or schedule of your own that runs `quotapilot share --yes` keeps sending until you remove it. Aggregates already published in the public repository's history are not rewritten.

## How long shared data is kept

| Data | Where | Kept |
|---|---|---|
| Random install id | Only on your computer (`install-id`) or in your browser's local storage | Until you delete it; it is never stored on the server |
| Anonymous reports (the fields listed above) under a keyed hash of the install id | Collector | 31 days, or until you delete them |
| First-seen day of that hash | Collector | 31 days after it was first seen, or until you delete it |
| Network hash in each report (a daily-salted hash of the /24 or /48 network) | Inside the report | With the report |
| Rate-limit counters (keyed hashes of IP + day or install hash + day) | Collector | 1–2 days |
| Visit records (keyed hash of IP + day, no cookies) | Collector | 8 days |
| Daily visit totals (views, visitors) | Collector | 400 days |
| Published statistics (`community.json`, aggregates only) | Public | Rebuilt every 6 hours from the last 7 days (limit events: 30 days) |
| IP addresses | Never stored; Cloudflare handles connections under its own policy | — |

Each report is stored under a key built from the anonymous reporter hash, so deleting an install's reports normally completes immediately: nothing waits for expiry. Under heavy load a deletion can be refused for the rest of the day (the collector limits how many deletions it accepts a day); the app or website then retries later.

Choose what to share in the menu bar (**What to share**: speed, prompt and cache tokens, plan quota, limit events) or with `quotapilot share --only speed,quota`.

## AI Quota Watch website

The website counts visits without cookies: each visit is stored as a hash of the IP address and the day only (no user agent) that is kept for 8 days, and only daily totals (views, visitors) are kept after that, for up to 400 days. The site shows the visitor figure only at 500 or more a week. It is a sum of daily visitors: because no identifier is kept across days, the same person visiting on two days counts twice. Visit counting stops at a daily write cap, so busy days undercount. Reports sent from the website's form follow the collector rules above.

The report form can use Cloudflare Turnstile. It is switched on only when the site has a Turnstile key configured; check `turnstileSiteKey` in `site/assets/config.js`: an empty key means no Cloudflare code loads and the collector relies on its per-network rate limits and daily budgets instead. When it is on, it runs only after you press "Preview report" (nothing from Cloudflare loads when the page opens), to check that a human is sending. Turnstile runs in your browser under Cloudflare's privacy policy and sets no tracking cookies for us. We keep nothing from it: the one-time token is checked once with Cloudflare and discarded.

## Stored locally

In `~/Library/Application Support/QuotaPilot/`:

- `history.json`: quota samples and a hashed account identifier.
- `tokens.json`: cumulative token samples and a hashed account identifier.
- `status.json`: current widget diagnostics, selected plan/window, operational settings, and the active task's title and optional project/issue/model labels.
- `task-ledger.json`: manually entered Codex task metadata, elapsed-time boundaries, retry counts, outcomes, and validation notes.
- `account-observations.json`: quota and account-token snapshots captured at task boundaries, kept separate from task-attributed usage.
- `usage-events.jsonl` (plus archived `usage-events-<time>.jsonl` files over 20 MB) and `usage-event-state.json`: append-only account-level quota/token checkpoints and source events, plus the latest checkpoint used to detect data gaps.
- `usage-stats.json` (statistics window): hourly token totals per provider, sparse quota samples and output-speed totals, kept 35 days.
- `instance.lock`: prevents duplicate processes.

Language, observation duration, rate unit, position, and collapse/pin preferences are stored in the app's defaults domain. Account email/id is used in memory to derive an identifier; raw credentials are never persisted by the widget.

Histories (`history.json`, `tokens.json`) are trimmed to a 31-day horizon and the statistics file (`usage-stats.json`) to 35 days when samples are collected. Resets, counter corrections, plan/account changes, or gaps over 5 minutes can clear the affected observation segment earlier. If the widget is stopped or offline, existing files remain until collection resumes or the user removes them.

The task ledger is local and manual. It stores user-entered task titles, project/issue references, model/reasoning labels, retries, outcomes, and notes; the account observation file stores quota percentages, reset times, a hashed account key, and the reported account-wide token total at task start/end. These observations are not described as task consumption. The app keeps up to 5,000 task records and 10,000 task-boundary snapshots.

The usage event log has no automatic expiry in this prototype. It stores a 15-minute account checkpoint while polling is active, plus gap, account-switch, reset, source-correction, failure, and recovery events. It contains timestamps, quota values, the reported account-wide token total, source error codes, and hashed account keys; it contains no prompts or transcripts. **Export usage events…** copies the complete JSON Lines file to a user-selected location. Review it before sharing because it can reveal account usage patterns. Deleting the Application Support directory removes the local event log.

To delete collected data, quit the widget and remove its Application Support directory. Preferences can be removed separately using the macOS defaults domain `io.github.dwagwd.quotapilot`.

Local files and screenshots may disclose usage patterns. Share only redacted diagnostics. Public source archives deliberately exclude local state, credentials, and profiling output.

## Optional provider integrations

Claude Code and Antigravity CLI bridges receive official status-line JSON, normalize quota fields, and discard the raw payload. Only hashed session/account identity, observation time, and quotas are saved locally. Existing status-line commands are preserved; setup creates a local settings backup. The native widget reads changed snapshots every 15 seconds only when imports are enabled. Bridge history is kept in process memory.

The optional Cursor Teams collector sends an exact member-email filter to the official Cursor Team Admin API. Its admin key is entered in a terminal without echo and kept only in process memory. The key is never stored in a file, preference, command-line argument, model conversation, or log. No redirects are followed. The collector must be started manually and stopped with Ctrl-C. It does not retrieve browser cookies. Normalized snapshots contain no email or credentials.

The repository and packages exclude runtime snapshots and settings backups. Optional bridge removal instructions are in [providers.md](docs/providers.md).

## Local agent logs, auto-continue and API keys

- **Token breakdown:** when enabled (default), the widget reads the local logs of **Codex** (`~/.codex/sessions`), **Claude Code** (`~/.claude/projects`), **Gemini CLI** (`~/.gemini/tmp`) and **Grok CLI** (`~/.grok/logs`) and keeps only token counts, timestamps, a provider name and a de-duplication key in memory. Prompts, replies, tool output and file contents are not stored or sent anywhere.
- **Auto-continue** (off by default) reads the first line of recent Codex session files (session id and working folder) when a quota limit is first reached, to note which session was interrupted, and after the quota resets runs `codex exec resume` for that session only (if several sessions were active, it skips and tells you); Codex then sends a request with your Codex account. Its output is appended to `auto-continue.log` (mode 0600) in the widget's Application Support folder.
- **DeepSeek:** the API key is stored only in the macOS login keychain (this device only) and sent only to `https://api.deepseek.com/user/balance`.
- **Automatic connection** (your choice at first launch) edits `~/.claude/settings.json` or `~/.gemini/antigravity-cli/settings.json` only to add the status-line bridge, after writing a timestamped backup, and never replaces a non-command status line. It reads a DeepSeek key from Claude Code's `env` only when `ANTHROPIC_BASE_URL` points at a deepseek.com host; the key is not copied or stored.

The CLI honors the saved Claude-login and agent-log collection choices. Standalone CLI installations leave Claude credential access off until `quotapilot config claude-plan on`; `quotapilot config agent-logs off` stops log scanning in status, stats and sharing previews. Neither choice enables anonymous sharing.

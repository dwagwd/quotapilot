# Privacy and data handling

QuotaPilot runs on your Mac and has no account or server of its own for the app. This page lists what it reads, what leaves the computer and when, and what it stores. The defaults below are for version 0.6.

## What the app reads by default

- **Codex:** it asks the local Codex App Server for account identity, quota windows and the cumulative account token counter. Codex may make authenticated requests to OpenAI to answer. Codex's own policies apply.
- **Claude Code plan usage:** it reads Claude Code's stored login (the `Claude Code-credentials` keychain item through `/usr/bin/security`, or `~/.claude/.credentials.json`) and sends that token only to `https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code itself uses. The token is kept in memory and never written to disk.
- **Local agent logs (token breakdown, on by default):** it reads `~/.codex/sessions` and `~/.claude/projects` JSONL files and keeps only token counts, timestamps, model names, a provider name and a de-duplication key. Prompts, replies, tool output and file contents are not stored or sent.
- **Automatic connection (on by default):** it may edit `~/.claude/settings.json` or `~/.gemini/antigravity-cli/settings.json` to add the status-line bridge (see the last section).

It never starts model turns on its own unless you turn on **Auto-continue**, and it never redeems reset credits.

## What leaves the computer

- **Update checks (on by default):** once a day the app asks `api.github.com` for the latest QuotaPilot release, without account data. When a newer version exists, it is **downloaded in the background** to the app's cache folder so that installing later is instant. It is **installed only after you choose Install update…**, and only if the digest, code signature, signing team and notarization check out. Turning off **Check for updates automatically** stops both the check and the background download.
- **Claude and Codex usage requests:** described above; they go only to Anthropic and (through Codex) OpenAI.
- **Anonymous sharing:** only if you run `quotapilot share` or turn on **Share anonymous stats daily**. See below.
- Nothing else: no telemetry or analytics service.

## Anonymous sharing (opt-in)

Nothing is shared unless you run `quotapilot share` and confirm, or turn on **Share anonymous stats daily** (off by default). `quotapilot share --json` only prints what would be sent.

- **Default destination: the AI Quota Watch collector** (`collector/`, served at `https://aiquotawatch.pages.dev/api`). No GitHub account is used. The request carries a random id created on this computer (`install-id` in the data folder); the collector stores only a keyed hash of it, never the id itself or your IP address, and deletes reports after 35 days. The daily option uses the same anonymous path.
- **Optional public GitHub issue:** `quotapilot share --github` opens a prefilled issue in your browser, and `--submit` files it with the GitHub CLI. These are public under your GitHub name. Set `QUOTAPILOT_SHARE_REPO` to send them to a different repository.
- **Contents:** model ids, reasoning effort labels, plan names, output and reasoning tokens and call time per model and effort, quota percentage and tokens used per 5-hour or weekly window, and whether a limit was reached, with the time rounded to the hour. Reports can cover Codex, Claude Code, Gemini CLI and Grok CLI. They contain no prompts, file paths, project names, account ids or credentials.

## AI Quota Watch website

The website counts visits without cookies: each visit is stored with a daily-salted hash of the IP address and browser user agent that expires after 8 days, and only daily totals (views, visitors) are kept after that, for up to 400 days. Reports sent from the website's form follow the collector rules above.

## Stored locally

In `~/Library/Application Support/QuotaPilot/`:

- `history.json`: quota samples and a hashed account identifier.
- `tokens.json`: cumulative token samples and a hashed account identifier.
- `status.json`: current widget diagnostics, selected plan/window, operational settings, and the active task's title and optional project/issue/model labels.
- `task-ledger.json`: manually entered Codex task metadata, elapsed-time boundaries, retry counts, outcomes, and validation notes.
- `account-observations.json`: quota and account-token snapshots captured at task boundaries, kept separate from task-attributed usage.
- `usage-events.jsonl` (plus archived `usage-events-<time>.jsonl` files over 20 MB) and `usage-event-state.json`: append-only account-level quota/token checkpoints and source events, plus the latest checkpoint used to detect data gaps.
- `instance.lock`: prevents duplicate processes.

Language, observation duration, rate unit, position, and collapse/pin preferences are stored in the app's defaults domain. Account email/id is used in memory to derive an identifier; raw credentials are never persisted by the widget.

Histories are trimmed to a 31-day horizon when samples are collected. Resets, counter corrections, plan/account changes, or gaps over 5 minutes can clear the affected observation segment earlier. If the widget is stopped or offline, existing files remain until collection resumes or the user removes them.

The task ledger is local and manual. It stores user-entered task titles, project/issue references, model/reasoning labels, retries, outcomes, and notes; the account observation file stores quota percentages, reset times, a hashed account key, and the reported account-wide token total at task start/end. These observations are not described as task consumption. The app keeps up to 5,000 task records and 10,000 task-boundary snapshots.

The usage event log has no automatic expiry in this prototype. It stores a 15-minute account checkpoint while polling is active, plus gap, account-switch, reset, source-correction, failure, and recovery events. It contains timestamps, quota values, the reported account-wide token total, source error codes, and hashed account keys; it contains no prompts or transcripts. **Export usage events…** copies the complete JSON Lines file to a user-selected location. Review it before sharing because it can reveal account usage patterns. Deleting the Application Support directory removes the local event log.

To delete collected data, quit the widget and remove its Application Support directory. Preferences can be removed separately using the macOS defaults domain `io.github.dwagwd.quotapilot`.

Local files and screenshots may disclose usage patterns. Share only redacted diagnostics. Public source archives deliberately exclude local state, credentials, and profiling output.

## Optional provider integrations

Claude Code and Antigravity CLI bridges receive official status-line JSON, normalize quota fields, and discard the raw payload. Only hashed session/account identity, observation time, and quotas are saved locally. Existing status-line commands are preserved; setup creates a local settings backup. The native widget reads changed snapshots every 15 seconds only when imports are enabled. Bridge history is kept in process memory.

The optional Cursor Teams collector sends an exact member-email filter to the official Cursor Team Admin API. Its admin key is entered in a terminal without echo and kept only in process memory. The key is never stored in a file, preference, command-line argument, model conversation, or log. No redirects are followed. The collector must be started manually and stopped with Ctrl-C. It does not retrieve browser cookies. Normalized snapshots contain no email or credentials.

The repository and packages exclude runtime snapshots and settings backups. Optional bridge removal instructions are in [providers.md](docs/providers.md).

## Local agent logs, auto-continue and API keys

- **Token breakdown:** when enabled (default), the widget reads `~/.codex/sessions` and `~/.claude/projects` JSONL files and keeps only token counts, timestamps, a provider name and a de-duplication key in memory. Prompts, replies, tool output and file contents are not stored or sent anywhere.
- **Auto-continue** (off by default) reads the first line of recent Codex session files (session id and working folder) when a quota limit is first reached, to note which session was interrupted, and after the quota resets runs `codex exec resume` for that session only (if several sessions were active, it skips and tells you); Codex then sends a request with your Codex account. Its output is appended to `auto-continue.log` (mode 0600) in the widget's Application Support folder.
- **DeepSeek:** the API key is stored only in the macOS login keychain (this device only) and sent only to `https://api.deepseek.com/user/balance`.
- **Automatic connection** (on by default) edits `~/.claude/settings.json` or `~/.gemini/antigravity-cli/settings.json` only to add the status-line bridge, after writing a timestamped backup, and never replaces a non-command status line. It reads a DeepSeek key from Claude Code's `env` only when `ANTHROPIC_BASE_URL` points at a deepseek.com host; the key is not copied or stored.

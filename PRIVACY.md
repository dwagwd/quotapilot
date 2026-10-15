# Privacy and data handling

The widget asks a local Codex App Server for account identity, quota windows, and the reported cumulative account token counter. Codex may make authenticated requests to OpenAI to answer these queries. Codex's own configuration and data policies continue to apply.

The widget does not read conversation contents, session logs, prompts, or authentication files. It does not start model turns, redeem reset credits, send telemetry to a separate service, or upload local samples.

## Stored locally

In `~/Library/Application Support/CodexUsageWidget/`:

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

To delete collected data, quit the widget and remove its Application Support directory. Preferences can be removed separately using the macOS defaults domain `local.codex.usage-widget`.

Local files and screenshots may disclose usage patterns. Share only redacted diagnostics. Public source archives deliberately exclude local state, credentials, and profiling output.

## Optional provider integrations

Claude Code and Antigravity CLI bridges receive official status-line JSON, normalize quota fields, and discard the raw payload. Only hashed session/account identity, observation time, and quotas are saved locally. Existing status-line commands are preserved; setup creates a local settings backup. The native widget reads changed snapshots every 15 seconds only when imports are enabled. Bridge history is kept in process memory.

The optional Cursor Teams collector sends an exact member-email filter to the official Cursor Team Admin API. Its admin key is entered in a terminal without echo and kept only in process memory. The key is never stored in a file, preference, command-line argument, model conversation, or log. No redirects are followed. The collector must be started manually and stopped with Ctrl-C. It does not retrieve browser cookies. Normalized snapshots contain no email or credentials.

The repository and packages exclude runtime snapshots and settings backups. Optional bridge removal instructions are in [providers.md](docs/providers.md).

## Local agent logs, auto-continue and API keys (0.5)

- **Token breakdown:** when enabled (default), the widget reads `~/.codex/sessions` and `~/.claude/projects` JSONL files and keeps only token counts, timestamps, a provider name and a de-duplication key in memory. Prompts, replies, tool output and file contents are not stored or sent anywhere.
- **Auto-continue** (off by default) reads the first line of recent Codex session files (session id and working folder) and runs `codex exec resume`; Codex then sends a request with your Codex account. Its output is appended to `auto-continue.log` (mode 0600) in the widget's Application Support folder.
- **DeepSeek:** the API key is stored only in the macOS login keychain (this device only) and sent only to `https://api.deepseek.com/user/balance`.


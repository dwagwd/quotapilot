# Changelog

## Unreleased

- **Open at login** option (Settings), using a macOS login item.
- **Connect detected agents automatically** (Settings, on by default): on launch and every 30 minutes the widget installs the Claude Code / Antigravity status-line bridge where the status line is free or a shell command (keeping the old command and backing up settings), turns on provider imports, and reads the DeepSeek balance with a keychain key or the key Claude Code uses for api.deepseek.com.
- **All agents token row:** totals tokens across Codex and Claude Code from local session logs, split into input, cache read, cache write, output and reasoning, per provider. Claude Code pointed at DeepSeek, Kimi, GLM or Qwen is attributed to that model family. Only token counts are read.
- **Remaining quota:** the reset line shows the remaining percentage next to the countdown.
- **Auto-continue (optional, off by default):** when a full Codex window resets, run `codex exec resume` once for the session that was interrupted, in its project folder; output goes to `auto-continue.log`.
- **Connect agents…** menu: one-click Claude Code / Antigravity quota bridges (bundled in the app), and a DeepSeek balance from an API key kept in the login keychain.
- Find the Codex CLI inside newer ChatGPT desktop builds (`Resources/codex-cli/`). Previously the widget stopped updating after the ChatGPT app moved the CLI.

## 0.4.0

- Release tooling: optional universal (arm64 + x86_64) builds, Developer ID signing with the hardened runtime, notarization and stapling in `package.sh`, and a Homebrew cask template.
- Add optional quota alerts (off by default): a system notification once per reset cycle when a quota reaches 90% or would run out before reset at the current pace.
- Archive the usage event log at 20 MB as `usage-events-<UTC time>.jsonl`; exports include archives.
- Keep unreadable task/observation ledgers as `*.corrupt-<time>.json` instead of overwriting them; repair torn JSONL lines, roll back failed appends, and cap the unsent event buffer.
- Translate token, bridge, and account-mismatch error codes in event history, and clear account-mismatch failures once identities match again.
- Add a pace forecast: the quota rate tooltip shows the projected usage at reset, or when the window reaches 100% first; the rate turns orange when it would run out before reset, and `status.json` exposes `forecast`.
- Add per-source freshness diagnostics with last attempt/success times, data age, retries, and bridge snapshot errors.
- Add a local Codex task ledger for task metadata, elapsed time, retries, and verification outcome.
- Add an append-only usage event ledger with account checkpoints, data gaps, account switches, quota resets, source corrections, and source recovery events.
- Save account quota and token-counter snapshots separately from task consumption; do not infer per-task usage from account-wide changes.
- Add local JSON/JSONL exports for task records, linked account observations, and the long-term usage event stream.

## 0.3.1 — First public source release

- Correct provider-specific freshness/tooltips and suppress unrelated Codex errors on other providers.
- Reject invalid percentages consistently and hide expired quota rates in status snapshots.
- Support reinstalling when the existing app runs from a different location.
- Create provider settings backups and temporary files with private permissions from the outset.
- Report the actual app version during app-server initialization.
- Publish source installation instructions, checksums, and the release audit scope.

## 0.3.0

- Ten interface languages plus automatic system selection.
- Compact percentage-rate notation with explicit percentage-point definitions.
- Optional additional quota rows, RGB text/background controls, and energy saver.
- Cache rates, suspend hidden UI updates, and update only countdown text on timer ticks.
- Optional official Claude Code/Antigravity CLI status-line bridges and Cursor Teams spend-cap collector.
- Backward-compatible preference migration, bridge validation, and private GitHub CI preparation.

## 0.2.0

- Added a settings gear in both card sizes and an editable settings window.
- Added English, Traditional Chinese, Simplified Chinese, and follow-system language modes.
- Added configurable 1-minute to 30-day observation windows and independent minute/hour/day rate units.
- Added account token consumption alongside plan quota consumption; each uses its own reported counter.
- Display backend plan labels and restart quota observation when the plan changes.
- Preserve quota when token usage is unsupported or times out; migrate existing quota history.
- Prepared MIT licensing, contributor/privacy/security guidance, macOS CI, and sanitized source/app packaging.

## 0.1.0

- Initial native floating card, quota windows, reset countdown, hourly quota rate, and Codex launch plugin.
- Added local persistence, stale-data behavior, subprocess recovery, and single-instance startup.

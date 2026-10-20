# Changelog

## Unreleased

- **Choose what each agent line shows** (Settings): reset time, quota rate, tokens, output tok/s, model, effort and the all-agent total can each be turned off.
- Compact and Bars styles now follow Settings: custom text color, and the quota selection (per agent; a selected window the backend no longer reports, such as an old Codex secondary window, keeps that agent visible). Each agent line adds its output tok/s and current model/effort (e.g. `opus-5-5/med`, `gpt-6.1-sol/medium`); Claude effort comes from Claude Code's log.
- Fix intermittent link failures and a possible wrong app binary: the app and CLI products were `QuotaPilot` and `quotapilot`, the same file on case-insensitive disks. The app product is now `QuotaPilotApp`.
- The card's headline token rate is now output tok/s (decode lower bound) instead of all tokens per second; the all-token figure, dominated by cache reads, is labelled "consumption incl. cache" in the tooltip, and the Codex account row says "incl. cache".
- **Output speed (decode lower bound):** per model call, output tokens (including reasoning) divided by the call's wall time — from the prompt or tool result to the end of the response (Codex `token_usage_record`, Claude Code's last block of each message). Shown in the All agents tooltip, a new chart in Usage statistics, and `quotapilot status/stats`. Because the time includes prefill and time to first token, it is a lower bound on decode (TG) tok/s; the existing token/s figures remain total tokens over wall-clock time.
- **Current model and reroute detection:** shows the model each agent is using (Codex: requested model and reasoning effort from the session log; Claude Code: the model that actually answered). When Codex reports a `model_reroute` (the server answered with a different model than requested, e.g. for content it flags as high-risk), the card marks the agent with ⚠︎, sends a notification, and `status.json` / `quotapilot status` list the reroute with its reason.
- **Windows and Linux: the `quotapilot` command-line tool.** `status`, `watch`, `route <web|review|plan|implement>`, `stats` and `config` work on macOS, Linux and Windows: Codex quota through the Codex app server, Claude plan usage through the Claude Code login (`~/.claude/.credentials.json`, or the keychain on macOS), token breakdowns from local logs, and the same quota router and task rules. The core no longer depends on Apple-only APIs. The menu bar app remains macOS-only.
- Fix Codex quota going stale: request rate limits before `account/read`, which current Codex app servers do not answer first.
- **Renamed to QuotaPilot** (app, executable, bundle ID `io.github.dwagwd.quotapilot`, data folder `~/Library/Application Support/QuotaPilot`, build variables `QUOTAPILOT_*`). The first launch moves the old data folder (leaving a symlink for installed bridges), copies preferences, and moves a saved DeepSeek key; the install script removes the old app.
- **Per-second rates:** choose seconds as the rate unit (tokens/s, %/s); small quota rates get more decimals.
- The 30-day statistics backfill reads file by file and resumes after a restart.
- **Quota order** (Settings): as detected, most used, resets soonest or by name, plus pinning one agent to the top; applies to the compact, bar and detailed extra rows.
- **Task routing rules** (Agent collaboration): choose Codex, Claude or Automatic separately for web/research, code review, planning, and implementation/other work. Rules fall back to the other agent when the chosen one is under 10% quota; `status.json` exposes `router.byTask`, which the skills follow.
- **Orchestrator mode** (Agent collaboration): `orchestrate-codex` lets Claude Code plan, write a spec, have Codex implement with `codex exec --sandbox workspace-write`, then verify the diff and checks itself and send focused fixes back (up to three rounds); `orchestrate-claude` is the same with Codex planning and Claude Code implementing (`claude -p --permission-mode acceptEdits`). Workers never commit or delegate.
- **Card style** (Settings): Detailed (original), Compact (one line per agent such as `Claude  5h 37% ↻2h39m  wk 96% ↻4h29m  ≈2%/h 780M`, with the all-agent token total in the title), or Bars (a small bar per limit). In Detailed, the selected window's sibling limits stay on the same line.
- **Agent collaboration** (menu bar → Agent collaboration…, each option off until chosen): a `codex-review` skill lets Claude Code get an independent read-only review from `codex exec`; a `claude-review` skill lets Codex get one from `claude -p` in plan mode; separately, Codex can use Claude Code's tools over MCP (`claude mcp serve`), which is not a Claude review. Skills check the quota router first, and a delegated run never delegates again (`AGENT_DELEGATION_DEPTH`).
- **Quota router** (Automatic / Codex first / Claude first): every 5-hour and weekly window counts, the tightest window decides an agent's headroom, a window resetting within 30 minutes counts as replenished, and agents under 10% are skipped. `status.json` exposes `router` (`agent`, `reason`, per-agent `headroom`).
- **Usage statistics window** (menu bar → Usage statistics…): 24h / 7d / 30d totals and averages per hour, token curves per provider with an input / cache / output / reasoning breakdown, and quota-used curves with percentage points consumed per hour for every window. History is kept for 35 days in `usage-stats.json`; the first launch backfills 30 days of agent logs and earlier Codex quota checkpoints.
- **Claude Pro/Max plan usage without a status line:** the 5-hour and weekly limits come from the same usage endpoint Claude Code uses, with the Claude Code login (macOS asks once for keychain access). Works for the Claude desktop app and remote sessions. Connected providers are added to the card automatically the first time.
- The All agents row lists the top providers (for example `Codex 1.7B · Claude 780M`).
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

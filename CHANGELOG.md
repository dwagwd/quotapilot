# Changelog

## Unreleased

- Collector: reports, counters and visit records are stored in Cloudflare D1 instead of Workers KV, which lifts the daily caps that came from KV's 1,000 writes a day. Older data stays readable and deletable.

## 0.6.7

- Sharing privacy: a report names a model only when it belongs to a public family; private deployments and locally named models are left out on your computer and refused by the collector. The request no longer carries the system's user agent or interface language.
- `quotapilot open` starts the menu bar app from the terminal after a Homebrew install; `quotapilot open --link` also adds it to `~/Applications` so Spotlight finds it.
- Menu bar: items are grouped (card, everyday windows, tasks and records, anonymous sharing, updates), and a new **About QuotaPilot** submenu links the website, the GitHub page and the issue form.
- After sharing, the app and `quotapilot share` point to the community numbers on AI Quota Watch.
- Website: every plan and reset page shows how to install the app; the empty community section says how many more people are needed and links example data.
- Faster statistics backfills: avoid copying the growing call-deduplication table and quota history for every observation; preserve streamed updates and independent snapshots.
- Compact and Bars cache shared token/speed totals until their time window or source data changes, and avoid resetting unchanged titles and progress bars.
- Optional system readings poll only the selected sensors, reuse the temperature client and skip hidden/sleeping-card polling.
- History backfill stops when log collection is disabled and resumes from completed files. Cancelled reads do not skip unprocessed usage. Save statistics on a normal quit.
- Recover unscanned usage after widget downtime. The CLI honors saved collection choices; standalone Claude credential access is opt-in, and the app exposes it in Settings.
- Website: complete installation commands, platform-specific actions, working project-path hosting and standalone previews, durable visitor rollups and a corrected page-top link.

## 0.6.6

- First launch now asks before QuotaPilot reads Claude Code's saved login (Claude plan usage) or edits other agents' settings files (automatic connection). A new install starts with both off; an existing install keeps its choices and is asked to confirm them once. **Connections and privacy…** in the menu bar changes them later.
- Homebrew bottle: releases now include a prebuilt package built on GitHub's runners, so `brew install` no longer has to compile on Macs the bottle covers.
- Website: `/resets/` index pages, the Chinese home page links the Chinese reset history, and a test checks every internal link.
- Privacy policy: who runs the service and how to reach us, where data is processed, and what changed.
- Windows CI now runs the test suite.
- Website: third-party benchmark numbers (intelligence, speed, cost per task) are no longer republished. The model radar, effort ladder and effort pages are gone; the calculator now compares monthly API cost from each vendor's own price list and links to Artificial Analysis for benchmarks.
- Website report form: Cloudflare Turnstile is on.
- README rewritten around what the app does, with the full feature list moved to `docs/features.md`; both READMEs link the live website.
- Website data re-checked on 2026-11-12: Claude Fable 5.2 and Gemini 4 Carbon API prices, the announced Gemini price increases, and two reported plan tiers.

## 0.6.5

- **Command-line tool for Linux and Windows, built by GitHub:** each release now carries `quotapilot` for Linux (x64, ARM64) and Windows (x64; it also runs on ARM PCs) as a single file with a SHA-256 checksum, compiled on GitHub's own runners, so no personal machine is involved. The macOS app is still compiled by Homebrew on your Mac.
- **AI Quota Watch install box:** it picks Linux, Windows or macOS from your browser (locally, nothing is sent) and shows the matching command; buttons switch system and direct GitHub download links are listed for every platform.
- CI also builds and tests on Linux ARM.

## 0.6.3

- **Built on your Mac, no prebuilt app:** Homebrew now compiles QuotaPilot from source (`brew install dwagwd/quotapilot/quotapilot`, about two minutes) instead of installing a signed download. Update with `brew upgrade quotapilot`; the menu bar still tells you when a new version is tagged. The in-app downloader stays off because no signed builds are published.
- **Delete what you shared:** `quotapilot share --forget`, the menu bar's **Delete my shared stats…** and a link on the website delete every anonymous report from that computer or browser on the collector.
- **Prompt and cache statistics:** shared reports add new input, cache-read and cache-write token totals; AI Quota Watch shows each model's prompt-to-output ratio and cache share once 3 people report it.
- **Only the data the stats need:** the collector and the GitHub issue path share one field list; text fields accept only known values (no free text, so the site form's app field is now a list), numbers are range-checked, times are cut to the hour, and reports are kept 31 days instead of 35.
- **Choose what to share:** a **What to share** menu (speed, prompt and cache tokens, plan quota, limit events) and `quotapilot share --only …`; PRIVACY.md lists how long each kind of data is kept.
- **Protection against poisoned data:** the collector refuses reports dated in the future or more than 8 days back; the stats drop impossible numbers (speed above 4× the model's benchmark or 2,000 tok/s, calls over 15 minutes, absurd prompt or quota totals) before they reach a row; and a public "feels worse" warning now needs 5 people, 3 of whom say so.
- **Anonymous sharing only:** `--github` / `--submit` and the website's GitHub fallback are gone, the community workflow no longer reads GitHub issues, and the issue template is removed. Reports go only to the anonymous collector.
- **Stronger privacy for everyone who shares:** the hour-of-day chart of limit events now needs 3 different people per provider like every other row (before, it could show one person's working hours).
- Builds no longer embed the build machine's folder paths, and the build refuses to package a binary that still contains one.
- AI Quota Watch: the top strip now separates when sources were checked by hand, when community data was compiled, and when the page last loaded (it no longer says LIVE / "Data just now"). Plan rows label price, usage multiple and limits separately, so a third-party price on an otherwise official row is visible. The model radar leaves unknown values unscored (dashed outline with a "?" marker) instead of scoring them 0. The report form shows the exact payload before **Send anonymously**. Links to #sections land below the sticky top bar, also on first load.
- AI Quota Watch: the calculator opens with a workload pick: set a quality bar, then see the cheapest and the fastest priced model that clear it, with the reason and limits one click away. Models without a score or a verified price are listed as not compared instead of being ranked. Presets set a suggested quality bar.

## 0.6.2

- **`quotapilot` command comes with the app:** the app bundle now includes the CLI (`QuotaPilot.app/Contents/Helpers/quotapilot`) and the Homebrew cask puts it on `PATH`, so `quotapilot share` works right after `brew install --cask`.
- **Auto-continue resumes the right session:** the interrupted Codex session is noted when the limit is first reached, and only that session is resumed after the reset. If several sessions were active, QuotaPilot asks you to resume manually instead of guessing. It resumes only when every quota window has a fresh reading below the limit, and gives up if the account changed.
- **Routing:** an agent that is at its limit is no longer chosen for work now, even when its reset is minutes away.
- **Token counts:** a Claude Code reply that is rewritten while it streams is counted with its final token numbers instead of the first partial line.
- Privacy notice rewritten around the current defaults (log reading, background update downloads, collector vs. GitHub sharing).
- AI Quota Watch: community rows need three different people, visit counting no longer loses concurrent visits and visitor hashes expire after 8 days, table sorting works from the keyboard, and the report form keeps your report with a retry and GitHub option when the collector is down.

## 0.6.1

- **Anonymous sharing:** `quotapilot share` and **Share anonymous stats daily** now send reports to the AI Quota Watch collector instead of filing GitHub issues. No GitHub account is involved; the collector keeps only a keyed hash of a random id for this computer, never your IP address, and deletes reports after 35 days. `--github` or `--submit` still file an issue.
- AI Quota Watch moved to https://aiquotawatch.pages.dev/ (Cloudflare Pages, with the collector at `/api`).
- Claude Max plans show as Max 5x or Max 20x (from Claude Code's rate-limit tier) in the card, status and shared reports. Claude rate history restarts once after updating.

## 0.6.0

- **Updates inside the app:** QuotaPilot checks GitHub once a day (turn off with **Check for updates automatically** in the menu bar), downloads a new version in the background with progress in the menu, verifies the SHA-256 digest, code signature, Developer ID team and notarization, and notifies once. **Restart to update** then swaps it in within seconds and keeps your settings. A failed download retries once; nothing installs without your click.
- **AI Quota Watch:** the project website now lives in `site/` (plan quotas for GPT, Claude, Grok and Gemini, Codex reset history, reasoning-effort comparisons, community stats).
- **`quotapilot share` (opt-in):** previews anonymous speed per model and reasoning effort, quota percentage against tokens used per 5-hour or weekly window, and limit hits, then shares them only if you confirm. `--submit` files the report with the GitHub CLI; **Share anonymous stats daily** in the menu bar (off by default) does it once a day. No prompts, paths, project names or account ids.
- **Gemini CLI and Grok CLI token logs** are read for the All agents totals (Gemini also gives output speed per model).
- Speed samples record the model and reasoning effort; Claude Code thinking tokens are counted as reasoning.
- On Windows, links open without passing through `cmd`.

- Fix Claude quota rate, pace forecast and quota alerts: Claude's usage endpoint returns a slightly different sub-second reset time on almost every request, which restarted the rate history on each refresh (so Claude never showed a rate or forecast) and could re-send the 90% alert. Reset times within 60 seconds now count as the same reset.
- `quotapilot --help` and `--version` work as flags; fractional `--hours` are shown as `30m` or `1.5h` instead of `0h`/`1h`.

## 0.5.0

Renamed to **QuotaPilot** (repository `dwagwd/quotapilot`; old links redirect). Adds the cross-platform `quotapilot` CLI with Linux builds.

- **Fixes from a full review:** re-running the Claude/Antigravity status-line setup after the rename no longer makes the bridge call itself (it now wraps what the old bridge wrapped); turning "Import other agents" off stays off; Settings keeps quota windows of a provider that is temporarily offline; lengthening the observation window or re-enabling agent logs rescans instead of showing too few tokens; `quotapilot config` changes now reach the macOS app; `status.json`, `history.json` and `tokens.json` are user-only (0600) and the data folder 0700; reinstalling replaces the app instead of merging into it; Codex request timeouts and retries fire while a menu is open; installing a bridge no longer blocks the UI and times out; a hung original status-line command no longer crashes the bridge; reroute notifications are not repeated after a restart; Cursor spend over the cap shows 100% instead of nothing; Claude plan history is kept per account; `--hours` rejects invalid values; saving the DeepSeek key updates it in place instead of delete-then-add.
- Fix repeated keychain prompts for "Claude Code-credentials": Claude Code rewrites that item on every token refresh, which reset the app's "Always Allow". The token is now read through `/usr/bin/security` and cached until it expires.
- **System readings (optional):** CPU %, GPU %, temperature (°C or °F, hottest die sensor on Apple silicon), RAM % and disk % on the card, each chosen in Settings; sampled every 5 s (15 s with energy saver) only while shown.
- **App icon:** a quota gauge with a paper-plane needle, drawn by `scripts/make-icon.swift` (`assets/AppIcon.icns`).
- The Settings window fits the screen, scrolls, resizes, and zooms (pinch, or − / 100% / + in its title bar).
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

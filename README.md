# Codex Usage Widget

A small, native macOS desktop widget for **plan quota**, **account token consumption**, and **reset countdowns**. Built with AppKit and Swift, without a browser runtime or model-turn polling.

[繁體中文](README.zh-TW.md) · [Privacy](PRIVACY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)

Unofficial community project. Not affiliated with or endorsed by OpenAI, Anthropic, Google, or Cursor. Product names belong to their respective owners.

## Features

- Draggable 260 × 128 pt card; collapsible 182 × 32 pt capsule, with a settings gear in both modes.
- Separate plan-quota and Codex account token rates. Compact `%/h` notation means percentage points per hour (20% → 25% in one hour = 5%/h).
- Keep one selected quota or add up to four additional quotas. The card grows vertically; collapse returns to one compact capsule.
- Custom text/background RGB values (0–255) or automatic system appearance.
- Energy saver: 120-second network polling and 15-second display updates. Hidden cards stop the UI timer; rate calculations are cached until new samples arrive.
- Optional Claude Code and Antigravity CLI status-line bridges; Cursor Teams on-demand spend-cap collector. [Provider support and setup](docs/providers.md)
- **Card style** (Settings): Detailed, Compact (one line per agent with every limit, rate and tokens; total usage in the title) or Bars (one small bar per limit).
- **Agent collaboration** (menu bar → Agent collaboration…): choose a `codex-review` skill for Claude Code (independent read-only review via `codex exec`), a `claude-review` skill for Codex (review via `claude -p` in plan mode), and, separately, Codex access to Claude Code's tools over MCP. A **quota router** (Automatic / Codex first / Claude first) weighs every 5-hour and weekly window and their reset times; skills consult it before delegating and never delegate twice.
- **Usage statistics** window (menu bar → Usage statistics…): 24h / 7d / 30d token totals and tokens per hour, curves per provider, and quota-used curves with the average percentage points consumed per hour. The first launch backfills 30 days from local logs.
- **All agents** row: total tokens across Codex and Claude Code (plus DeepSeek, Kimi, GLM or Qwen models used through Claude Code) read from local session logs, with an input / cache read / cache write / output / reasoning breakdown per provider in the tooltip. Only token counts are read; turn it off in Settings.
- Remaining quota and countdown on the reset line (for example `57% left · reset 02:10:00`).
- Optional **auto-continue** for Codex (Settings, off by default): when a quota window that was full resets, the interrupted session is resumed once with `codex exec resume` in its project folder. This starts a model turn using your Codex configuration; output is written to `auto-continue.log`.
- **Agents connect automatically** (Settings → Connect detected agents automatically, on by default): Claude Code and Antigravity quota bridges are installed when those agents are found, and a DeepSeek balance appears when Claude Code is configured for DeepSeek or a key is saved. **Connect agents…** in the menu bar shows the status and does the same manually: connect Claude Code or Antigravity quota with one click, or add a DeepSeek API key (stored in the login keychain) to show the balance.
- Optional quota alerts (Settings → Quota alerts, off by default): one notification per reset cycle when a quota reaches 90% or would run out before reset at the current pace. Requires the installed app bundle.
- Pace forecast: hover the quota rate to see the projected usage at reset, or how long until 100% at the current pace. The rate turns orange when the window would run out before it resets. This is a linear projection, not a promise.
- Observation window: **1 minute to 30 days**, entered as a whole number of minutes, hours, or days.
- Independent rate display unit: per minute, hour, or day.
- English, Traditional/Simplified Chinese, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Italian, or follow the system language. New task/diagnostic labels are translated in English and Chinese and fall back to English in the other languages.
- Actual backend quota windows and plan names, including distinct model buckets when available.
- Local sample history, saved position/settings, stale-data indicators, automatic reconnection, and manual startup.
- Source diagnostics for Codex and optional bridges; a long-term account usage event ledger for gaps, account switches, resets, and source corrections; and local task records with verification outcomes. Task-specific token attribution stays unavailable unless a source can directly identify a session.

## Build and install

Requirements: macOS 13+, Swift 5.9+ / Xcode Command Line Tools, Python 3 for tests and packaging, and Codex desktop or CLI signed in with a ChatGPT account. The core Codex app is native and does not require Python; optional provider bridges use Python 3.

**Quick install:** download `CodexUsageWidget-<version>-macos-universal.zip` from [Releases](https://github.com/dwagwd/codex-plugin/releases/latest), unzip it, and move **Codex Usage Widget.app** to Applications. It is signed and notarized, so it opens without a Gatekeeper warning.

**From source:** download the source ZIP from [Releases](https://github.com/dwagwd/codex-plugin/releases/latest), extract it, and open a terminal in the extracted `codex-usage-widget` folder. Or clone the repository:

```sh
git clone https://github.com/dwagwd/codex-plugin.git codex-usage-widget
cd codex-usage-widget
```

Then build and launch:

```sh
./scripts/check.sh
./scripts/build-install.sh
./scripts/launch.sh
```

The app is installed at `~/Applications/Codex Usage Widget.app`. Reopening it reveals the existing instance. Turn on **Open at login** in Settings to start it with macOS. Use the menu bar item to hide/show, refresh, pin, or quit.

Click the **gear** to configure language, observation window, rate units, additional quotas, RGB colors, energy saving, and provider imports, then **Apply**. Click the card title to select a quota window. Drag blank space to move the card. Hover over each rate for its source and actual observed duration.

Use the menu bar item to open **Source diagnostics…**, start or finish a Codex task record, review task/event history, or export either ledger. Account-wide quota and token observations stay separate from task consumption; see [the prototype notes](docs/task-ledger.md).

A Codex plugin manifest and launch skill are included. See [Codex plugin setup](docs/plugin.md).

## What the numbers mean

| Metric | Source | Calculation and scope |
|---|---|---|
| Plan quota | `account/rateLimits/read` | Observed percentage-point increase in the selected quota window. The displayed plan is backend-reported. |
| Account tokens | `account/usage/read` → `summary.lifetimeTokens` | Observed increase in the account-wide reported cumulative token counter. This is not a per-model measurement. |
| Reset countdown | `resetsAt` | Time until the backend-provided reset; reaching zero does not assume the reset occurred. |

**Tokens are not converted into quota using fixed multipliers.** Models and plans can consume quota differently. Shared quota buckets do not expose attribution to each model, so the widget reports actual bucket changes and does not label them as one model's usage. A distinct Spark bucket is separate from the main shared Codex bucket.

Rates are estimates: differences are divided by elapsed observation time, including idle time, and scaled to the selected display unit. “Per day” scales the observed pace; it is not a promise of future consumption. The footer shows the requested observation window, and tooltips show each metric's actual observed duration.

The default is the latest hour, shown per hour. Warmup requires the shorter of 5 minutes or the requested window. Shorter-than-requested observations are labeled estimates. No historical samples are invented when extending the window. Counters can update late; zero token rate means no reported increase, not proof of zero model activity.

Quota resets, decreases, plan changes, account switches, clock reversal, or gaps over 5 minutes restart the affected observation segment. Token counter corrections and account switches similarly restart token observation. Up to 31 days of samples are kept while collecting; stopped or offline installations retain their last files until collection resumes or the files are removed. An interrupted multi-day session therefore does not produce a continuous multi-day rate.

Missing or unsupported token data shows `—` while quota continues to work. API-key-only accounts may not expose these ChatGPT usage endpoints. Codex authentication stays with Codex; the widget never reads or copies authentication files or starts model turns.

## Development and packaging

```sh
./scripts/check.sh     # Swift tests + source export hygiene
./scripts/build.sh     # Build/sign locally, without installing
./scripts/package.sh   # Architecture-specific app ZIP + portable source ZIP
```

Builds use `~/Library/Caches/CodexUsageWidget/` by default. Override `CODEX_WIDGET_BUILD_CACHE`, `CODEX_WIDGET_TEST_CACHE`, or `CODEX_WIDGET_DIST_DIR` as needed. `CODEX_USAGE_CODEX_PATH` selects a custom Codex executable when launching the native executable directly.

Packages use ad-hoc signing and are **not notarized**. Source builds are the supported installation path for this version. A manual GitHub Actions packaging workflow creates downloadable artifacts; it does not publish releases. [Release checklist](docs/releasing.md)

## Local data and removal

Samples and diagnostic snapshots are stored in `~/Library/Application Support/CodexUsageWidget/`. Preferences use the `local.codex.usage-widget` defaults domain. Avoid uploading these files or unredacted screenshots to public issues.

To remove: quit the widget, remove its app, optionally remove its local data and preferences, and remove the plugin from Codex if installed. No daemon is installed; a login item exists only if you turn on **Open at login**.

## Status

Version 0.4.0 adds a Developer ID signed, Apple-notarized universal (Apple silicon + Intel) app ZIP alongside the source ZIP and SHA-256 checksums. Codex is the live-tested provider. Optional Claude/Antigravity/Cursor bridges are experimental and fixture-tested; see their support boundaries before setup. CI tests and builds on macOS 14 and 15. See [validation scope](docs/validation.md) for local checks and limitations.

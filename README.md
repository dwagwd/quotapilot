# QuotaPilot

[![Latest version](https://img.shields.io/github/v/tag/dwagwd/quotapilot?label=version)](https://github.com/dwagwd/quotapilot/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE) ![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey) ![CLI: macOS · Linux · Windows](https://img.shields.io/badge/CLI-macOS%20%C2%B7%20Linux%20%C2%B7%20Windows-lightgrey)

**See how much Codex and Claude Code quota you have left before you hit the limit.** A small native macOS card and menu bar item, plus a `quotapilot` command for macOS, Linux and Windows. It shows the quota used in each 5-hour and weekly window, how fast you are burning it, and when it resets.

<img src="assets/screenshot-card.png" width="380" alt="QuotaPilot card showing Claude and Codex quota, token rates and reset countdowns">

```sh
brew tap dwagwd/quotapilot https://github.com/dwagwd/quotapilot
brew install dwagwd/quotapilot/quotapilot
open "$(brew --prefix quotapilot)/QuotaPilot.app"
```

On Apple Silicon Macs with macOS 15 or later, Homebrew installs a prebuilt package in a few seconds. On other Macs it builds QuotaPilot from source (about two minutes, needs the Xcode Command Line Tools). Update with `brew upgrade quotapilot`. Linux and Windows: [get the command-line tool](#windows-and-linux-the-quotapilot-cli).

<!-- sponsor:start --><!-- sponsor:end -->

**[AI Quota Watch](https://aiquotawatch.pages.dev/)** is the project's website: plan limits, reset history and community-measured speed for ChatGPT, Claude, Gemini and Grok, every number with its source ([site source](site/)).

[繁體中文](README.zh-TW.md) · [All features](docs/features.md) · [Privacy](PRIVACY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)

Unofficial community project. Not affiliated with or endorsed by OpenAI, Anthropic, Google, or Cursor. Product names belong to their respective owners.

## Why QuotaPilot

- **Native and light.** AppKit and Swift, no browser runtime. In a one-minute local measurement the app used about 27 MiB of memory and 0.05% of one CPU core ([how it was measured](docs/validation.md#resource-measurement)).
- **It asks first.** The first launch asks before it reads Claude Code's saved login or touches another agent's settings file. Codex quota needs neither.
- **Nothing leaves your Mac unless you say so.** No telemetry. Anonymous sharing is off by default, shows exactly what it would send, and can be deleted later. [Privacy details](PRIVACY.md)
- **It never spends your quota.** It reads usage; it does not start model turns (unless you turn on auto-continue) and never redeems reset credits.

## Features

**See your quota**
- Plan quota per 5-hour and weekly window for Codex and Claude Code, with remaining percentage and reset countdown.
- Optional quota from Antigravity, Cursor Teams and a DeepSeek balance; token usage from Gemini CLI and Grok CLI. [Provider support](docs/providers.md)
- A draggable card that collapses to a small capsule, in Detailed, Compact or Bars style, with up to five quotas at once.

**Know before it runs out**
- Burn rate in percentage points per hour, and a forecast of where you will be at reset.
- Optional alerts at 90% used or when the current pace would run out before the reset.
- Optional auto-continue: resume an interrupted Codex session once the window resets.

**Use the agent that has room**
- A quota router that picks Codex or Claude for web research, review, planning and implementation, and falls back when one is low.
- Review and orchestrator skills so one agent plans and checks while the other implements.
- `quotapilot route review` prints the agent to use, for your own scripts.

**Look back**
- Usage statistics for 24 hours, 7 days and 30 days, with token totals per agent and model.
- Local task records and an account event log you can export.

Ten interface languages. The complete list is in [docs/features.md](docs/features.md).

## Windows and Linux: the `quotapilot` CLI

The menu bar app is macOS-only. On **macOS, Linux and Windows** the `quotapilot` command shows the same data and router:

```sh
quotapilot status            # quota per agent, tokens (24 h), routing by task
quotapilot watch             # refresh in the terminal every 60 s
quotapilot route review      # prints codex or claude (exit 3 if both are low)
quotapilot stats --hours 168 # tokens by agent and purpose for 7 days
quotapilot config rule web codex
quotapilot status --json     # for scripts and skills
quotapilot share             # opt-in: preview anonymous speed/quota numbers, then share them with AI Quota Watch
```

On macOS the Homebrew formula puts `quotapilot` on `PATH` (the tool ships inside the app at `QuotaPilot.app/Contents/Helpers/quotapilot`). On Linux and Windows download the single-file build (Linux x64 or ARM64, Windows x64) from the [latest release](https://github.com/dwagwd/quotapilot/releases/latest) and check it against the `.sha256` file next to it, or build it yourself with Swift 6.2 or later: `swift build -c release --product quotapilot` (binary in `.build/release/`). It needs the Codex CLI on `PATH` for Codex quota. Claude plan usage requires an existing Claude Code login and permission to read it: standalone CLI installs opt in with `quotapilot config claude-plan on`. The CLI honors the app’s saved collection choices on macOS; `quotapilot config agent-logs off` disables local log scanning. Settings are stored in `~/.local/state/quotapilot/cli-config.json` (Linux) or `%LOCALAPPDATA%\QuotaPilot\cli-config.json` (Windows); on macOS the app's settings are used.

## Build and install

Requirements: macOS 13+, Swift 5.9+ / Xcode Command Line Tools, Python 3 for tests and packaging, and Codex desktop or CLI signed in with a ChatGPT account. The core Codex app is native and does not require Python; optional provider bridges use Python 3.

**Quick install:** use the Homebrew commands at the top; they compile and install QuotaPilot on your Mac.

**From source:** clone the repository:

```sh
git clone https://github.com/dwagwd/quotapilot.git quotapilot
cd quotapilot
```

Then build and launch:

```sh
./scripts/check.sh
./scripts/build-install.sh
./scripts/launch.sh
```

The app is installed at `~/Applications/QuotaPilot.app`. Reopening it reveals the existing instance. Turn on **Open at login** in Settings to start it with macOS. Use the menu bar item to hide/show, refresh, pin, or quit.

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

Builds use `~/Library/Caches/QuotaPilot/` by default. Override `QUOTAPILOT_BUILD_CACHE`, `QUOTAPILOT_TEST_CACHE`, or `QUOTAPILOT_DIST_DIR` as needed. `CODEX_USAGE_CODEX_PATH` selects a custom Codex executable when launching the native executable directly.

Builds are ad-hoc signed on the machine that compiles them (set `QUOTAPILOT_SIGN_IDENTITY` to sign with your own Developer ID). No signed app is published. The only prebuilt macOS package is the Homebrew bottle, built on GitHub's runners; `./scripts/build.sh` compiles locally. The manual GitHub Actions packaging workflow only creates ad-hoc artifacts for testing. [Release checklist](docs/releasing.md)

## Local data and removal

Samples and diagnostic snapshots are stored in `~/Library/Application Support/QuotaPilot/`. Preferences use the `io.github.dwagwd.quotapilot` defaults domain. Avoid uploading these files or unredacted screenshots to public issues.

To remove: quit the widget, remove its app, optionally remove its local data and preferences, and remove the plugin from Codex if installed. No daemon is installed; a login item exists only if you turn on **Open at login**.

## Status

The current version is on the badge at the top; changes are in [CHANGELOG.md](CHANGELOG.md). Codex and Claude Code are used daily by the maintainers. The Antigravity and Cursor bridges are experimental and tested with fixtures only. CI builds and tests on macOS 15, Linux x64 and ARM64, and Windows x64; macOS 13 and 14, Intel Macs and Windows on ARM should work but are not tested by CI. See [validation scope](docs/validation.md).

If QuotaPilot is useful to you, a star helps other people find it. Problems and ideas are welcome in [issues](https://github.com/dwagwd/quotapilot/issues).

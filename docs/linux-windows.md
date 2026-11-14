# QuotaPilot on Linux and Windows: plan and status

Last updated 2026-11-14.

## Goal

People on Linux and Windows get the same three things Mac users get, with the same privacy and a light footprint:

1. **See their quota and usage**: plan quota per window, tokens, speed, reset countdown, which agent has room.
2. **Share anonymously and compare**: send the same anonymous statistics, and see how their numbers compare with the community.
3. **Stay light**: no browser runtime, no background service unless they ask for one, a few tens of MB of memory.

## What exists today (0.6.8)

The `quotapilot` command-line tool is built for Linux x64, Linux ARM64 and Windows x64 by the release workflow and
attached to every GitHub release. It does everything except draw a desktop card:

| Feature | macOS app | `quotapilot` on Linux / Windows |
|---|---|---|
| Codex quota per window | yes | yes (`status`, `watch`) |
| Claude Code plan quota | yes, after the first-launch question | yes, after `quotapilot config claude-plan on` (off by default; reads `~/.claude/.credentials.json`) |
| Tokens and speed from Codex, Claude Code, Gemini CLI, Grok CLI logs | yes | yes (`stats`) |
| Which agent has room | yes | yes (`route review`) |
| Anonymous sharing with preview and delete | yes | yes (`share`, `share --forget`) |
| Compare with the community | statistics window | `compare`, and after `share` |
| Always-visible card, notifications | yes | no: run `quotapilot watch` in a terminal |

## Acceptance check (runs in CI on every push)

`scripts/platform-acceptance.py` runs the built tool the way a person would. CI runs it on Linux x64, Linux ARM64
and Windows x64 after writing small synthetic Claude Code and Codex logs. It checks:

- **Works**: version, status, stats, config, route and the share preview answer.
- **Uploads**: `share --yes` reaches a collector (a local listener in the test) and `share --forget` asks for deletion.
- **Privacy**: the upload holds only the allowed statistics fields, a fixed `QuotaPilot` user agent, no cookie or
  authorization header, and none of the planted prompt text, project folder name, private model name, user name,
  home path or host name. Times are rounded to the hour.
- **Light**: peak memory under 200 MB and the steady-state CPU of `watch` under 10% of one core.

Results from the first run (2026-11-14, GitHub runners, synthetic logs):

| System | `stats` peak memory | `watch` steady CPU | Upload and privacy checks |
|---|---:|---:|---|
| Linux x64 | 35 MB | 0.01% | all passed |
| Linux ARM64 | 34 MB | 0.01% | all passed |
| Windows x64 | 20 MB | 0.05% | all passed |
| macOS (development Mac, a heavy real day: 361 MB of logs) | 163 MB RSS, 88 MB footprint | 1.6% | all passed |

No GPU is used anywhere: the tool prints text.

What CI cannot show: a real person's machine with a signed-in Codex and Claude Code. The Codex part needs the
Codex CLI on `PATH`; CI has none, so it checks that the tool reports the missing source and carries on.

## Plan

| # | Step | Status | How it is tested |
|---|---|---|---|
| 1 | CLI builds for Linux x64/ARM64 and Windows x64, attached to releases | done (0.6.4) | release workflow |
| 2 | Test suite runs on Linux and Windows | done (0.6.6) | CI |
| 3 | Acceptance check: works, uploads, privacy, CPU and memory | done (0.6.8) | CI on all three, script above |
| 4 | Log reading 5x faster; `watch` reads only new bytes | done (0.6.8) | acceptance + development Mac |
| 5 | `quotapilot compare`: your numbers next to the community | done (0.6.8) | unit tests |
| 6 | Daily sharing without the app: documented `cron` (Linux) and Task Scheduler (Windows) lines that run `quotapilot share --yes` | next | manual on a VM |
| 7 | A one-line installer per system (shell script for Linux, PowerShell for Windows) that checks the SHA-256 | next | CI downloads and runs it |
| 8 | Tray / taskbar item showing the tightest quota | needs a decision (below) | VM with a desktop |
| 9 | Real-machine smoke test before announcing Linux and Windows | needs a machine | see "Testing with real desktops" |

## Decision needed: a desktop item on Linux and Windows

The Mac card is AppKit, which does not exist elsewhere. Options, lightest first:

1. **Stay terminal-only** (`watch`). Zero extra code and footprint. Many developers on Linux already live in a terminal.
2. **Native tray icon per system**: Windows `Shell_NotifyIcon` through Swift's Windows bindings; Linux
   StatusNotifierItem over D-Bus (GNOME needs an extension to show it). Small and light, but two separate
   implementations to maintain.
3. **A small cross-platform tray library** (for example a Go or Rust helper that runs `quotapilot status --json`).
   One codebase, a few MB, but a second language in the repo.
4. Electron or a web view: rejected, it breaks the "light" goal (hundreds of MB).

Recommendation: ship 6 and 7 first (they cost little and make sharing and installing easy), then build option 2 for
Windows only if people ask; Linux users are best served by the terminal and by `quotapilot status --json` in their
own status bars (waybar, polybar, tmux).

## Testing with real desktops

- **Linux**: Docker is not installed on the Mac mini; CI already covers headless Linux. For a desktop session, a
  UTM virtual machine with Ubuntu ARM64 runs on Apple Silicon. Installing UTM needs Danny's OK.
- **Windows**: GitHub's `windows-latest` runner covers the CLI. For a desktop with a tray, Windows 11 ARM in UTM
  works on Apple Silicon and runs x64 programs through emulation; it needs a Windows licence for long-term use.

## Open questions

- Claude plan quota is off by default in the command-line tool and needs `quotapilot config claude-plan on`. Should
  `status` print a one-line hint when Claude Code is installed but the option is off? Recommended: yes, in 0.6.9.

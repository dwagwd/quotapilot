---
name: usage-widget
description: Launch, show, configure, or diagnose the local QuotaPilot desktop widget, displaying account quota, reset countdown, and configurable token and plan-quota consumption rates.
---

# QuotaPilot

Use the scripts bundled with this plugin; resolve paths relative to this SKILL.md.

- To launch or show the widget, run `../../scripts/launch.sh` with an absolute path. This builds and installs the companion app on first use. Launching it again reveals the existing widget.
- To rebuild after source changes, run `../../scripts/build-install.sh`, then launch.
- Use the gear on the card to set language (system or ten supported languages), observation interval (1 minute to 30 days), rate unit (minute/hour/day), additional quota rows, RGB text/background colors, energy saver, and optional provider imports, then Apply. Other settings are in the macOS menu bar item: show/hide, refresh, collapse/expand, always on top, and quit. Click the card title to choose a quota window; drag blank card space to move it.
- To connect Claude Code or Antigravity CLI, read `../../docs/providers.md` and use `../../scripts/setup-provider.py` for the requested provider. It preserves existing status-line output and backs up settings. Cursor Teams requires the separate interactive collector and an administrator key; never ask the user to paste keys into a model conversation. Do not imply Cursor personal quota or Antigravity IDE-only monitoring is supported.
- For diagnosis, use **Source diagnostics…** in the menu bar or read `~/Library/Application Support/QuotaPilot/status.json`. Check `sources` for each source's health, last attempt/success, data age, retry state, and error code; keep `lastUpdate` as the quota sample timestamp. `usageEventCount` is the append-only ledger event count, and the local event-ledger writer is reported separately. It contains local usage state, not credentials. Never present old snapshots as current account usage.
- To record a Codex task, use **Start task…** before work and **Finish task…** after verification. Record the task title, project/repository, issue/PR, model, reasoning effort, retries, and outcome. **Task history…** reviews records; **Export task ledger…** writes a local JSON bundle. The task timer measures elapsed wall-clock time, including idle and sleep.
- **Usage event history…** shows recent account checkpoints, observation gaps, account switches, quota resets, source corrections, and source failures/recovery. **Export usage events…** copies the complete append-only JSON Lines history; ordinary checkpoints are stored at 15-minute intervals and there is no automatic expiry.
- Task-specific token attribution is unavailable unless a source directly identifies a session. Account token and quota snapshots may show changes during a task, but they remain account-level observations and must not be called task consumption. Review exported project names, issue references, notes, and usage patterns before sharing.
- Quota rate uses compact `%/h` notation for observed percentage points in the selected plan window. Account token rate comes separately from account/usage/read cumulative reported tokens. Never use a fixed token-to-quota multiplier or imply shared quota can be attributed to a single model.
- Rates use the configured contiguous observation interval and display unit. Warmup is the shorter of 5 minutes or the requested interval. Shorter observed periods are labeled estimates. Missing token data is unavailable, not zero. Token reporting may lag. Resets, decreases, plan/account changes, or gaps over 5 minutes restart the affected segment.
- The app uses the existing Codex login through a managed app-server process. It does not start model turns. If login is missing, direct the user to sign in to Codex. Do not read or copy auth tokens.
- Do not modify the Codex app or Pet. This is an independent native companion. Do not consume usage-reset credits.
- Manual startup only. Quitting the widget stops its managed app-server process.

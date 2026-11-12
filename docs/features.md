# QuotaPilot features in detail

The [README](../README.md) has the short version. This is the full list.

- Draggable 260 × 128 pt card; collapsible 182 × 32 pt capsule, with a settings gear in both modes.
- Separate plan-quota and Codex account token rates. Compact `%/h` notation means percentage points per hour (20% → 25% in one hour = 5%/h).
- Keep one selected quota or add up to four additional quotas. The card grows vertically; collapse returns to one compact capsule.
- Custom text/background RGB values (0–255) or automatic system appearance.
- Energy saver: 120-second network polling and 15-second display updates. Hidden cards stop the UI timer; rate calculations are cached until new samples arrive.
- Optional Claude Code and Antigravity CLI status-line bridges; Cursor Teams on-demand spend-cap collector. [Provider support and setup](docs/providers.md)
- **Quota order** (Settings): sort agents by detection order, usage, next reset or name, and pin one agent to the top.
- **Task routing rules**: pick who handles web/research, review, planning and implementation (Codex, Claude or Automatic), with automatic fallback when that agent is low on quota.
- **Orchestrator mode** (Agent collaboration…): one agent plans and verifies while the other only implements — Claude Code → Codex (`orchestrate-codex`) or Codex → Claude Code (`orchestrate-claude`), with up to three fix rounds and quota checks.
- **Card style** (Settings): Detailed, Compact (one line per agent with every limit, rate and tokens; total usage in the title) or Bars (one small bar per limit).
- **Agent collaboration** (menu bar → Agent collaboration…): choose a `codex-review` skill for Claude Code (independent read-only review via `codex exec`), a `claude-review` skill for Codex (review via `claude -p` in plan mode), and, separately, Codex access to Claude Code's tools over MCP. A **quota router** (Automatic / Codex first / Claude first) weighs every 5-hour and weekly window and their reset times; skills consult it before delegating and never delegate twice.
- **Usage statistics** window (menu bar → Usage statistics…): 24h / 7d / 30d token totals and tokens per hour, curves per provider, and quota-used curves with the average percentage points consumed per hour. The first launch backfills 30 days from local logs.
- **All agents** row: total tokens across Codex and Claude Code (plus DeepSeek, Kimi, GLM or Qwen models used through Claude Code) read from local session logs, with an input / cache read / cache write / output / reasoning breakdown per provider in the tooltip. Only token counts are read; turn it off in Settings.
- **Updates** (menu bar): checks GitHub's version tags once a day (turn off with **Check for updates automatically**) and notifies once per new version; update with `brew upgrade quotapilot`.
- **Share anonymous stats daily** (menu bar, off by default): once a day sends the same numbers `quotapilot share` previews to [AI Quota Watch](https://aiquotawatch.pages.dev/) anonymously (no account; the collector keeps only a hashed id of this computer). `quotapilot share --yes` does the same from cron or launchd, and `quotapilot share --forget` deletes everything this computer sent.
- Remaining quota and countdown on the reset line (for example `57% left · reset 02:10:00`).
- Optional **auto-continue** for Codex (Settings, off by default): when a quota window that was full resets, the interrupted session is resumed once with `codex exec resume` in its project folder. This starts a model turn using your Codex configuration; output is written to `auto-continue.log`.
- **You choose what it connects to**: the first launch asks whether QuotaPilot may read Claude Code's saved login to show Claude plan usage (through the unpublished endpoint Claude Code itself uses, which Anthropic may change or restrict) and whether it may connect detected agents. Both are off until you say yes; change them later under **Connections and privacy…** in the menu bar.
- **Agents connect automatically** (when you allowed it; Settings → Connect detected agents automatically): Claude Code and Antigravity quota bridges are installed when those agents are found, and a DeepSeek balance appears when Claude Code is configured for DeepSeek or a key is saved. **Connect agents…** in the menu bar shows the status and does the same manually: connect Claude Code or Antigravity quota with one click, or add a DeepSeek API key (stored in the login keychain) to show the balance.
- Optional quota alerts (Settings → Quota alerts, off by default): one notification per reset cycle when a quota reaches 90% or would run out before reset at the current pace. Requires the installed app bundle.
- Pace forecast: hover the quota rate to see the projected usage at reset, or how long until 100% at the current pace. The rate turns orange when the window would run out before it resets. This is a linear projection, not a promise.
- Observation window: **1 minute to 30 days**, entered as a whole number of minutes, hours, or days.
- Independent rate display unit: per minute, hour, or day.
- English, Traditional/Simplified Chinese, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Italian, or follow the system language. New task/diagnostic labels are translated in English and Chinese and fall back to English in the other languages.
- Actual backend quota windows and plan names, including distinct model buckets when available.
- Local sample history, saved position/settings, stale-data indicators, automatic reconnection, and manual startup.
- Source diagnostics for Codex and optional bridges; a long-term account usage event ledger for gaps, account switches, resets, and source corrections; and local task records with verification outcomes. Task-specific token attribution stays unavailable unless a source can directly identify a session.

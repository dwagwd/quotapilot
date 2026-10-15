# Connecting other coding agents

**Fastest path:** open the menu bar icon → **Connect agents…**. It shows what is detected and connects Claude Code or Antigravity quota with one click (the bridge scripts ship inside the app), or stores a DeepSeek API key for the balance. Token usage for Codex and Claude Code needs no setup: it is read from local session logs (see the All agents row). When Claude Code is pointed at DeepSeek, Kimi, GLM or Qwen through an Anthropic-compatible endpoint, its tokens are attributed to that model family.

All integrations are optional. Enable **Import other agents** in the gear menu after setup. A provider appears when its first valid snapshot arrives. Select it from the card title or add it to the multiple-quota list. No quotas are combined across providers.

| Provider | Integration | What it measures | Requirements / limitations |
|---|---|---|---|
| Codex | Managed local app-server | Actual plan quota; account-reported token counter | Existing Codex ChatGPT login |
| Claude Code | Official status-line JSON bridge | Five-hour and seven-day quota | A Claude Code version/account that emits `rate_limits`; active CLI session |
| Antigravity CLI | Official status-line JSON bridge | Model/bucket quotas from `quota` | CLI status-line support; active CLI session. IDE-only installation is not enough |
| Cursor Teams | Official Team Admin API collector | On-demand spend as a percentage of the enforced per-user spending cap | Team Admin API key and exact member email. **Not personal plan quota or included usage** |

Claude and Antigravity integrations are event-driven: when their CLI stops reporting, the card retains the last value, marks it stale after five minutes, and hides its rate. A sleeping or idle CLI may therefore show stale data. The widget checks changed snapshot files every 15 seconds. No prompts or model turns are created.

## Claude Code and Antigravity CLI

From this checkout (Python 3 required):

```sh
python3 scripts/setup-provider.py claude
# Or:
python3 scripts/setup-provider.py antigravity
```

The installer copies the bridge into the widget's local Application Support folder, backs up existing settings, and preserves the previous status-line shell command and its output. It does not read authentication files. Run it only for the provider you want to connect. Existing non-command status-line configurations require manual integration instead of being overwritten.

Restart or use the provider's CLI, enable imports in widget Settings, and wait for a status-line update. Missing quota fields remain unavailable; **context-window occupancy is never substituted for plan quota or cumulative token consumption**. Other providers' context token fields are deliberately not presented as a consumption rate.

Claude's documented status-line quota payload has no guaranteed account identity. We isolate its history by session ID; switching or interleaving sessions restarts the baseline conservatively. Antigravity uses a hash of its reported account identity, with session identity as fallback. Identity hashes and normalized quotas are kept locally; raw payloads, email, paths, prompts, and transcripts are not stored. Bridge rate history currently lasts for the widget process lifetime and resets after restart.

To remove a bridge, restore the timestamped `settings.json.usage-widget-backup-*` file in `~/.claude/` or `~/.gemini/antigravity-cli/`, or manually restore only the previous `statusLine` setting if you have made later unrelated changes. Disable imports in widget settings. Then remove the provider snapshot and copied bridge files if desired.

## Cursor Teams

```sh
python3 scripts/cursor-collector.py --watch
```

The terminal asks for your exact team member email and **Team Admin API key**. The key is hidden on entry and held only in that collector's memory. It is never written to preferences, passed in command-line arguments, logged, or sent to a model. The collector calls only `https://api.cursor.com/teams/spend`, every 120 seconds, with failure backoff capped at five minutes. Redirects are rejected. Use Ctrl-C to stop; omit `--watch` for a single snapshot.

The calculation is `spendCents / (effectivePerUserLimitDollars × 100) × 100`. Included usage is excluded. A changed cap or billing-cycle start resets the baseline. No cap yields an unknown percentage. Values beyond the enforced cap are labeled “exceeded” with an unavailable percentage rather than clamped to a fictitious exact value. The endpoint does not provide a reset timestamp, so the card reports it as unknown. We do not infer a reset from calendar months.

Cursor individual plan monitoring, per-model shared-plan quota attribution, and Antigravity IDE-only monitoring are **not supported** in this version. No browser-cookie extraction, credential scraping, or undocumented private endpoint is used.

## Data and freshness contract

Snapshots are restricted to `claude.json`, `antigravity.json`, and `cursor.json` under `~/Library/Application Support/CodexUsageWidget/providers/`. Files are written atomically with mode 0600, and the native importer accepts at most 256 KiB, 32 windows, a known provider, bounded identifiers, and a plausible observation timestamp. Provider IDs namespace every quota. Errors preserve the previous sample until it becomes stale; they never report zero usage. A gap over five minutes resets speed estimation.

## Official references

- [Claude Code status line fields](https://code.claude.com/docs/en/statusline)
- [Antigravity CLI status-line fields](https://antigravity.google/docs/cli/statusline/)
- [Cursor Team Admin API](https://prod.cursor.com/docs/account/teams/admin-api)

Adapters are covered by sanitized contract fixtures. Live account verification has been completed for Codex; Claude, Antigravity, and Cursor require an actual configured account for live acceptance testing. Documentation and API schemas can change independently of this project.

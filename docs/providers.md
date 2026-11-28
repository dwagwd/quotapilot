# Connecting other coding agents

**Fastest path:** open the menu bar icon → **Connect agents…**. It shows what is detected and connects Claude Code or Antigravity quota with one click (the bridge scripts ship inside the app), or stores a DeepSeek API key for the balance. Token usage for Codex, Claude Code, Gemini CLI and Grok CLI needs no setup: it is read from local session logs (see the All agents row). When Claude Code is pointed at DeepSeek, Kimi, GLM or Qwen through an Anthropic-compatible endpoint, its tokens are attributed to that model family.

All integrations are optional. Enable **Import other agents** in the gear menu after setup. A provider appears when its first valid snapshot arrives. Select it from the card title or add it to the multiple-quota list. No quotas are combined across providers.

| Provider | Integration | What it measures | Requirements / limitations |
|---|---|---|---|
| Codex | Managed local app-server | Actual plan quota; account-reported token counter | Existing Codex ChatGPT login |
| Claude Code | Official status-line JSON bridge | Five-hour and seven-day quota | A Claude Code version/account that emits `rate_limits`; active CLI session |
| Antigravity CLI | Official status-line JSON bridge | Model/bucket quotas from `quota` | CLI status-line support; active CLI session. IDE-only installation is not enough |
| Gemini CLI | Local chat recordings (`~/.gemini/tmp/*/chats/*.jsonl`) | Tokens (input, cache, output, thoughts) and output speed per model | Token usage only; Gemini app plan quota is not exposed to local tools |
| Grok CLI | Local unified log (`~/.grok/logs/unified.jsonl`) | Tokens (prompt, cache, completion, reasoning) | Token usage only. The log has no model name or request start, so no per-model speed |
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

**Claude plan usage and the keychain.** When "Show Claude plan usage" is on, QuotaPilot prefers the Claude Code status-line bridge: a snapshot written by the bridge within the last five minutes is used as is, with no token, no keychain access and no request. Only when there is no fresh bridge data (Claude Code idle, desktop app only, bridge not connected) does it ask the usage endpoint, using Claude Code's login from `~/.claude/.credentials.json` if that file exists, else from the `Claude Code-credentials` keychain item. The keychain is read at most once per token lifetime (the token is kept in memory with its `expiresAt`, never on disk); an expired or rejected token is not read again until Claude Code has written a new item (QuotaPilot checks the item's modification date, which does not need permission); after a refused or cancelled read nothing is retried for six hours, the card shows "Claude login needs access" and the menu offers **Retry Claude login access**. What the bridge gives up compared with the usage endpoint: no `Claude Opus` / `Claude Sonnet` weekly windows, no plan name (Max 5x/20x), data only while a Claude Code session is active, and rate history is per session. macOS still asks once after Claude Code rewrites the item, when no fresh bridge data exists; that prompt comes from `/usr/bin/security` and cannot be avoided by signing. Separately, builds are ad-hoc signed and every build has a new code hash, so macOS may ask once after each upgrade about QuotaPilot's own keychain items (DeepSeek key, local-model keys); this is expected, and an identifier-only signing requirement was rejected because it would let any ad-hoc program with the same identifier read those items.

Claude's documented status-line quota payload has no guaranteed account identity. We isolate its history by session ID; switching or interleaving sessions restarts the baseline conservatively. Antigravity uses a hash of its reported account identity, with session identity as fallback. Identity hashes and normalized quotas are kept locally; raw payloads, email, paths, prompts, and transcripts are not stored. Bridge rate history currently lasts for the widget process lifetime and resets after restart.

To remove a bridge, restore the timestamped `settings.json.usage-widget-backup-*` file in `~/.claude/` or `~/.gemini/antigravity-cli/`, or manually restore only the previous `statusLine` setting if you have made later unrelated changes. Disable imports in widget settings. Then remove the provider snapshot and copied bridge files if desired.

## Cursor Teams

```sh
python3 scripts/cursor-collector.py --watch
```

The terminal asks for your exact team member email and **Team Admin API key**. The key is hidden on entry and held only in that collector's memory. It is never written to preferences, passed in command-line arguments, logged, or sent to a model. The collector calls only `https://api.cursor.com/teams/spend`, every 120 seconds, with failure backoff capped at five minutes. Redirects are rejected. Use Ctrl-C to stop; omit `--watch` for a single snapshot.

The calculation is `spendCents / (effectivePerUserLimitDollars × 100) × 100`. Included usage is excluded. A changed cap or billing-cycle start resets the baseline. No cap yields an unknown percentage. Values beyond the enforced cap are labeled “exceeded” with an unavailable percentage rather than clamped to a fictitious exact value. The endpoint does not provide a reset timestamp, so the card reports it as unknown. We do not infer a reset from calendar months.

Cursor individual plan monitoring, per-model shared-plan quota attribution, and Antigravity IDE-only monitoring are **not supported** in this version. No browser-cookie extraction, credential scraping, or undocumented private endpoint is used.

## Logs on an external disk

If `~/.codex`, `~/.claude` or another agent's log folder lives on an external or removable disk (for example a symlink to `/Volumes/...`), macOS asks once whether QuotaPilot may "access files on a removable volume". Choose Allow. macOS ties that answer to the app's code signature. Homebrew builds are ad-hoc signed, so each new version is a new signature and macOS asks again after `brew upgrade`; the command-line tool asks separately. If you build QuotaPilot yourself, signing it with your own Developer ID (`QUOTAPILOT_SIGN_IDENTITY`, see docs/releasing.md) keeps the answer across updates.

## Data and freshness contract

Snapshots are restricted to `claude.json`, `antigravity.json`, and `cursor.json` under `~/Library/Application Support/QuotaPilot/providers/`. Files are written atomically with mode 0600, and the native importer accepts at most 256 KiB, 32 windows, a known provider, bounded identifiers, and a plausible observation timestamp. Provider IDs namespace every quota. Errors preserve the previous sample until it becomes stale; they never report zero usage. A gap over five minutes resets speed estimation.

## Official references

- [Claude Code status line fields](https://code.claude.com/docs/en/statusline)
- [Antigravity CLI status-line fields](https://antigravity.google/docs/cli/statusline/)
- [Cursor Team Admin API](https://prod.cursor.com/docs/account/teams/admin-api)

Adapters are covered by sanitized contract fixtures. Live account verification has been completed for Codex; Claude, Antigravity, and Cursor require an actual configured account for live acceptance testing. Documentation and API schemas can change independently of this project.

## Local models (Ollama, LM Studio, llama.cpp, oMLX, Strata)

These have no quota, so they appear as usage only (provider `local`, $0, plus a hypothetical cost on a reference cloud model). Off by default.

| Tool | How it is counted | Setup |
|---|---|---|
| llama.cpp | `GET /metrics` counters every 60 s (tokens and seconds; no request count) | start `llama-server` with `--metrics` |
| oMLX | `GET /admin/api/usage?range=today` every 60 s | none; API key in the Keychain (or `QUOTAPILOT_OMLX_API_KEY` for the CLI) only if the server has one |
| Ollama, LM Studio, Strata, other OpenAI/Anthropic-compatible servers | metering proxy on 127.0.0.1 (Ollama 11434 gives 11435, Strata 8080 gives 8081) | turn the proxy on for the backend and point the client at the proxy URL |

The proxy copies bytes unchanged and reads only usage and timing fields. A streamed OpenAI-style request without `stream_options.include_usage` is counted as a request without token counts. See [local-llm.md](local-llm.md).

# AI Quota Watch vs codexradar.com: review and comparison

Reviewed 2026-11-02. Covers every file added for AI Quota Watch (`site/`) and the QuotaPilot code that feeds it (`quotapilot share`, log parsers, workflows). codexradar is described at the concept level only; we do not copy its design, text or data.

## 1. Review results

### Fixed in this pass (commit 7bd2009)

| Area | Problem | Fix |
|---|---|---|
| QuotaPilot `AgentModels.swift` | The new Gemini parser sat under Claude's doc comment | Each parser has its own comment |
| QuotaPilot `ContributionReport` | Claude Code calls to a non-Claude model (e.g. Gemini through a compatible API) were labeled "Gemini CLI" | Client comes from the log the sample came from |
| QuotaPilot `share` | A heavy user could produce a link longer than GitHub accepts; the ingester also kept only 20 rows | Shares are capped at 30 rows (busiest first), long links fall back to paste, ingester keeps 50 |
| Site timeline | "Upcoming" stayed on a change after its date | Only future-dated changes show as upcoming |
| Site live strip | "Since last Codex reset" would count any vendor's reset | Counts Codex (chatgpt) resets only |
| Site sources | Effort benchmark and reset trackers were missing from the source list | Added |
| `community-data.yml` | The 6-hourly run committed a new timestamp even with no new data, and every run redeployed Pages | Timestamp kept when data is unchanged; Pages deploys only after a successful data run |
| Data checks | `efforts.json` was not validated | Validated (source, provider, effort names) |
| SEO | No social preview tags | Open Graph and Twitter card tags added |

Tests after fixes: QuotaPilot 98 Swift tests + Python checks pass; site 10 aggregator tests, data check and translation check pass.

### Known limits (not bugs, but worth knowing)

1. **Gemini CLI and Grok CLI parsers are untested on real logs.** Neither tool is installed on the Mac mini. They follow the public file formats and have fixture tests. Verify on the first real machine that has them.
2. **ChatGPT plan rows are "Reported".** OpenAI's pricing and help pages block automated reading, so numbers come from third-party coverage.
3. **Reset ledger is maintained by hand.** X blocks automated reading; automatic ingestion would need X API access.
4. **Ad slots show as dashed placeholders.** Set `ads.showPlaceholders: false` in `site/assets/config.js` before going live unless an ad network is connected.
5. **Community stats are empty until people share.** `?demo=1` shows clearly labeled example data.
6. **Grok and Antigravity/Cursor give less data.** Grok's log has no model or start time (tokens only). Antigravity and Cursor bridges give quota % but no tokens (limit hits only).
7. **Single page.** Good for a tool, weak for search traffic. See "Gaps" below.

## 2. Feature comparison

| codexradar feature | What it does | AI Quota Watch | Status |
|---|---|---|---|
| Overview (速览) | One-screen summary | Hero + live strip | Done |
| Model IQ (模型智商) with own puzzles | Runs its own task set per model and effort | Uses Artificial Analysis per-effort index (12 models) | Partial: own benchmark planned as `quotapilot bench` |
| Pareto: cost, time, composite | Score vs cost and vs time per task | Intelligence vs cost scatter, effort ladder curves, model radar | Done (no time-per-task axis yet) |
| Community feel score /10 | Users rate models, 7-day window | "How it feels" rating, min 3 reports | Done |
| Degradation alert (降智预警) | Warns when a model seems worse | Warning when ≥30% of recent ratings say "feels worse" | Done |
| Live speed radar (全站实时均速) | Community client streams tok/s every 5 min | Measured speed from `quotapilot share`, 7-day median | Partial: not real-time, shares are manual |
| Effort selection rate (档位选择率) | Share of real requests per effort | "Share of calls" per effort from QuotaPilot shares | Done (needs data) |
| Reset prediction / status / ledger | Status, monthly stats, hour histogram, ledger with confirmation level | Reset radar: live clock, monthly chart, hour chart, ledger with official/tracker badges | Done, except prediction |
| Subscription quota (订阅额度) | Runs a fixed test on one account and converts % used into weekly $ and tokens | "Measured plan quota" from shares: tokens ÷ % used, plus API-$ equivalent | Done (needs data) |
| Tibo 28-day challenge calendar | Day-by-day calendar of improvements and resets | Ledger only | Gap |
| Tibo updates feed with translation and signal labels | Every Tibo post, translated, tagged direct/indirect/no reset signal | None | Gap (needs X API) |
| News, community notes (27 articles) | Long-form tips and explainers | None | Gap: biggest SEO gap |
| Points and rewards | Points for contributing, redeemable | None | Gap |
| Email subscribe | Updates by email | None | Gap (needs an email account) |
| Promo and quota intel | Discounts, free credit offers | None | Gap: natural place for affiliate links |
| Copy-the-prompt self test | Paste a puzzle into your own app | Not built (decided against pure-web testing) | Skipped by decision |
| Multi-vendor coverage | Codex only | ChatGPT, Claude, Gemini, Grok, Cursor, Antigravity | We lead |
| Bilingual | Simplified Chinese | English first, Traditional Chinese toggle | We lead for global traffic |
| Open-source data collector | Opt-in client | QuotaPilot (MIT), preview + y/N before sharing | Done |
| Calculator and budget radar | Not a focus | API cost calculator, 5-axis model radar | We lead |

## 3. Recommended next steps, ranked by revenue impact

1. **Go live** (push, enable Pages, set `showPlaceholders: false`). Nothing earns until the page is public.
2. **Content pages for search**: one static page per tool and plan ("Claude Max usage limit", "Codex reset history", "GPT-6.1 Sol effort levels"). These are what people search for, and codexradar wins on content.
3. **Promo/intel section** with affiliate links where programs exist.
4. **`quotapilot bench`**: our own auto-graded task set per model × effort, run weekly on the maintainer's own accounts, so intelligence and quota cost come from the same run.
5. **Reset prediction**: probability of a reset in the next 24 hours from the ledger's gaps and hours.
6. Email digest and contributor leaderboard, once there is traffic.

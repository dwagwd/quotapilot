# What we learned from codexradar.com (reviewed 2026-11-02)

Concept-level notes only. We do not copy its design, text or data.

| codexradar feature | What it does | Our version |
|---|---|---|
| 社区体感分 (community feel score /10, 7-day window, "mine" view) | Users rate models; public 7-day average | **Done**: "How it feels" rating, 7-day window, min 3 reports |
| 降智预警 (degradation alert) | Flags when a model seems to get worse | **Done**: warning when ≥30% of recent ratings say "feels worse" |
| 全站实时均速 / 速度雷达 (live speed from a community client) | Opt-in client reports tokens/s per model, harness, device; 5-min value + 24h trend | **Done**: manual speed reports plus `quotapilot share` (open-source QuotaPilot CLI, off by default, previews then asks before sharing measured speed and quota numbers) |
| 订阅额度 (measured plan quota) | Runs a fixed task set on one account, converts % used into weekly $ and tokens | **Done**: quota reports turn "% used + tokens used" into tokens per window and API $ equivalent |
| 重置雷达 / 台账 (reset radar + ledger) | Logs resets with confirmation level, counts by month and hour | **Done**: reset radar with live "time since last reset" clock, monthly counts, hour-of-day chart, ledger with official / tracker confirmation, plus community limit/reset reports |
| 全站实时 / 当前状态 (live status fields) | Live numbers that tick and refresh | **Done**: live strip under the header (time since reset, resets in 30 days, fastest community model, next change countdown), ticks every second, data refetched every 60 s |
| 档位选择率 (which effort tier people really use) | Share of real requests by model and reasoning effort | Later: needs an automatic client like the speed one |
| 模型智商 + 帕累托 (own benchmark, cost × time) | Own puzzle set, score vs cost and time | Partly: we chart Artificial Analysis index vs cost per task. Later: our own small task set |
| 雷达积分 (points for contributing, redeemable) | Rewards reporters | Later: leaderboard of top reporters by GitHub login (free, no payments) |
| 新闻 / 社区笔记 / 订阅 (news, notes, email updates) | Content and returning visitors | Later: notes become SEO pages; email needs an account, so not now |

## Collection design

- The site is static, so reports go out as prefilled **GitHub issues** (label `data-report`).
- `.github/workflows/community-data.yml` saves each report, re-aggregates every 6 hours, commits `data/community.json`, then thanks and closes the issue.
- Abuse limits: GitHub login required, one report per person per stat per day, IQR outlier trimming, rows hidden below 3 reports, value range checks.
- Cost: free on GitHub Pages + Actions. A Cloudflare Worker endpoint can replace issues later if the GitHub login step costs too many reports.

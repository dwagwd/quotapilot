# AI Quota Watch anonymous collector

Served as a Cloudflare Pages Function at `https://aiquotawatch.pages.dev/api/` (`site/functions/api/[[path]].js`
imports `worker.js`; bindings in `site/wrangler.toml`). It receives `quotapilot share` reports (and the site's report form) without any account.

- `POST /v1/forget` `{install}`: deletes every report this install sent and its first-seen record. Reports are
  stored under `r:<reporter>:<day>:<uuid>`, so this is a prefix list on `r:<reporter>:`. Keys in the older formats
  (`r:<day>:<reporter>:<uuid>`, `r:<day>:<uuid>`) are still deleted, by a cursor scan over every key with
  prefix `r:20` (those keys are no longer written and expire within 31 days; the scan runs only until
  `LEGACY_KEYS_UNTIL`, 2026-12-08). Forget first does the cheap checks (reads `rs:<reporter>` and lists the prefix, plus the legacy walk while it applies);
  when nothing is found it answers `{ok: true, deleted: 0}` without touching any counter. Only a forget that deletes something counts:
  it has its own cap of 5 a day across the collector (`rl:forget-day:<day>`, plus 5 per network /24 or /48); beyond it the answer is 429 `{error: "collector is full for today", full: true}`.
- `POST /v1/report` `{install, reports[]}`: keeps only the fields the statistics use (see `schema.js`: known values, id-like strings, bounded numbers, hour-precision times), stores them for 31 days under
  `anon-<HMAC(SALT, install id)>`. The install id, IP address and GitHub account are never stored.
- Limits: 20 KB per request, 30 reports, 3 submissions per computer and 20 per network per day
  (the network is the /24 for IPv4 or the /48 for IPv6; counters keyed by `HMAC(SALT, network + day)`, expiring
  after a day). The per-computer limit is checked first, so a looping install does not use up its network's budget.
  One network can introduce at most 2 new reporters (install ids never seen before) a day; that counter is keyed
  by `HMAC(SALT, "ip-new:" + network + day)`, holds only a number and expires after 2 days. Reporters already on
  record are never held back by it, and they do not write the per-network counter (one KV write saved per batch). The collector budgets KV writes by worst case with two daily batch counters:
  `rl:day:new:<day>` for batches from reporters not yet on record (15 a day, up to 6 writes each) and
  `rl:day:known:<day>` for reporters on record (40 a day, 3 writes each), so minted install ids cannot crowd out
  real reporters. Beyond a cap it answers HTTP 429 `{error: "collector is full for today", full: true}` before
  writing anything, so clients can detect it without matching the message. Free plan arithmetic (1,000 writes a day):
  15 x 6 + 40 x 3 + forget 5 x 96 + visit cap 150 + slack 160 = 1000 (worst case; deletes count as writes).
- `via` on a stored report is decided by the collector, and an `Origin` header alone never grants `site`. It is `site`
  only when the optional secret `TURNSTILE_SECRET` is set and the body's `turnstile` token (from the website form's
  Cloudflare Turnstile widget) verifies: `POST https://challenges.cloudflare.com/turnstile/v0/siteverify` with `secret`,
  `response` and `remoteip` (CF-Connecting-IP), 5 s timeout, answer `success` with a `hostname` that is one of the website
  origins. The check runs only for requests that ask to be `site` (a report with `via: "site"`, or an allowed website
  Origin). If it fails or the token is missing, the answer is 403 `{error: "verification failed"}` and nothing is stored
  and no counter is touched. Without `TURNSTILE_SECRET` the behaviour is otherwise unchanged but nothing is ever labelled
  `site` (it becomes `quotapilot`). QuotaPilot app requests (no Origin, `via: "quotapilot"`) never call siteverify.
  The token is checked once and discarded. The public site key goes in `site/assets/config.js` (`community.turnstileSiteKey`).
- Fields the collector adds to each stored report, so the stats can't be faked by minting install ids:
  - `reporterFirstSeen`: the day this reporter id was first seen. The record behind it (`rs:<reporter>`) holds only
    that day and expires 31 days after it was written, so an idle reporter is forgotten and later starts as new.
  - `receivedDay`: the day the collector received the report (the report's own `date` is chosen by the client).
  - `ipGroup`: 8 hex characters of `HMAC(SALT, /24 network (IPv4) or /48 network (IPv6) + day)`. It changes every
    day, covers a whole network rather than one address, and can't be turned back into an address without `SALT`.
- How the stats use them (`site/scripts/aggregate.mjs`): a reporter counts only once it is established, meaning
  it reported on a later day than its first-seen day, or on at least two different days. Its earlier reports then
  count too. Within each stats row, reporters that shared an `ipGroup` on a day count as one person and give
  one value. Older reports without these fields are counted as before.
- `POST /v1/hit` / `GET /v1/visits`: cookie-free 7-day visitor stats. Each visit is stored as its own key named
  with `HMAC(SALT, ip + day)` (12 characters; the user agent is left out so changing it can't add visitors) that
  expires after 8 days; finished days are rolled up
  into totals without hashes (`visits:<day>`), kept for 400 days. At most 150 visit writes a day. Every accepted view, including repeat visits, writes its own durable key, so cache eviction and the next-day rollup cannot erase accepted views. The cached today entry keeps up to 2,000 visitor hashes for approximate live unique counts. At the daily cap, additional views are not counted and `capped` is true. A finished day is rolled up only once it is at least 5 minutes past its UTC midnight end; before that it is served from the running counter. The cap is global but each data center only
  counts its own hits, so it lists today's hit keys when it has no counter and again after every 50 accepted hits;
  the global overshoot is therefore bounded by 50 x the number of data centers. `GET /v1/visits` reads only those
  rollup records (get, no list) plus today's views and visitors from the running counter, which is approximate until the
  day's rollup; it lists today only when there is no counter entry at all. The whole JSON response is cached for
  5 minutes with the Cache API. A finished day without a rollup is rolled up (listed once, then stored) the first time a request needs it.
- `GET /v1/export` (Bearer `EXPORT_TOKEN`): every stored report, pulled by `.github/workflows/community-data.yml`.

Deploys with the site (`.github/workflows/site-pages.yml`). Secrets: `SALT` and `EXPORT_TOKEN` on the Pages
project (optionally `TURNSTILE_SECRET`, see `via` above), and the matching `COLLECTOR_TOKEN` Actions secret. Tests: `node --test test/worker.test.mjs`.

## Abuse limits and accuracy

The per-network batch limit (20 a day per /24 or /48) applies to reporters not yet on record (new ids); reporters on record are limited by their own 3 submissions a day. All counters are approximate under concurrency: KV is eventually consistent and counters are read-modify-write, so simultaneous requests can briefly exceed a limit. The limits curb abuse; they are not exact counts.

Also add Cloudflare rate-limiting rules in the dashboard (Security > WAF > Rate limiting rules) for `POST /api/v1/report` and `POST /api/v1/hit`, so floods are stopped at the edge before they reach the Worker or KV.

## Data quality

The collector refuses reports dated in the future or more than 8 days back. `site/scripts/aggregate.mjs` then drops impossible values (speed above 4× the model's benchmark or 2,000 tok/s, calls longer than 15 minutes, absurd prompt or quota totals), counts each person once with their median, trims outliers, merges reporters sharing a network on the same day, waits until a reporter has been seen on two days, and publishes a row only from 3 people (a "feels worse" warning from 5, at least 3 of whom report it).

## Storage

Reports, rate-limit counters and visit records are stored in Cloudflare D1 (binding `DB` in `site/wrangler.toml`) through
`d1store.js`, which gives the collector the same get / put-with-expiry / delete / list-by-prefix calls it used on Workers KV.
The table is created on first use. D1's free plan allows 100,000 row writes a day (KV: 1,000), so the daily caps are higher
on D1 (`D1_BUDGET`). The KV namespace stays bound for reading and deleting data written before the move; it can be
unbound once those entries have expired (reports after 31 days). Without a `DB` binding the collector uses KV alone.
Tests: `node --test collector/test/d1store.test.mjs` runs the store against SQLite.

# AI Quota Watch anonymous collector

Served as a Cloudflare Pages Function at `https://aiquotawatch.pages.dev/api/` (`site/functions/api/[[path]].js`
imports `worker.js`; bindings in `site/wrangler.toml`). It receives `quotapilot share` reports (and the site's report form) without any account.

- `POST /v1/forget` `{install}`: deletes every report this install sent and its first-seen record.
- `POST /v1/report` `{install, reports[]}`: keeps only the fields the statistics use (see `schema.js`: known values, id-like strings, bounded numbers, hour-precision times), stores them for 31 days under
  `anon-<HMAC(SALT, install id)>`. The install id, IP address and GitHub account are never stored.
- Limits: 20 KB per request, 30 reports, 3 submissions per computer and 20 per IP address per day
  (counters keyed by `HMAC(SALT, ip + day)`, expiring after a day). One IP address can introduce at most 2 new
  reporters (install ids never seen before) a day; that counter is keyed by `HMAC(SALT, "ip-new:" + ip + day)`,
  holds only a number and expires after 2 days. Reporters already on record are never held back by it.
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
  into totals without hashes, kept for 400 days. At most about 500 visit writes a day (the cap is checked against
  a listing cached for up to 60 seconds).
- `GET /v1/export` (Bearer `EXPORT_TOKEN`): every stored report, pulled by `.github/workflows/community-data.yml`.

Deploys with the site (`.github/workflows/site-pages.yml`). Secrets: `SALT` and `EXPORT_TOKEN` on the Pages
project, and the matching `COLLECTOR_TOKEN` Actions secret. Tests: `node --test test/worker.test.mjs`.

## Data quality

The collector refuses reports dated in the future or more than 8 days back. `site/scripts/aggregate.mjs` then drops impossible values (speed above 4× the model's benchmark or 2,000 tok/s, calls longer than 15 minutes, absurd prompt or quota totals), counts each person once with their median, trims outliers, merges reporters sharing a network on the same day, waits until a reporter has been seen on two days, and publishes a row only from 3 people (a "feels worse" warning from 5, at least 3 of whom report it).

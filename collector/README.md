# AI Quota Watch anonymous collector

Served as a Cloudflare Pages Function at `https://aiquotawatch.pages.dev/api/` (`site/functions/api/[[path]].js`
imports `worker.js`; bindings in `site/wrangler.toml`). It receives `quotapilot share` reports (and the site's report form) without any account.

- `POST /v1/report` `{install, reports[]}`: keeps only known plain-text fields, stores them for 35 days under
  `anon-<HMAC(SALT, install id)>`. The install id, IP address and GitHub account are never stored.
- Limits: 20 KB per request, 30 reports, 3 submissions per computer and 20 per IP address per day
  (counters keyed by `HMAC(SALT, ip + day)`, expiring after a day).
- `POST /v1/hit` / `GET /v1/visits`: cookie-free 7-day visitor stats. Each visit is stored as its own key named
  with `HMAC(SALT, ip + user agent + day)` (12 characters) that expires after 8 days; finished days are rolled up
  into totals without hashes, kept for 400 days. At most about 500 visit writes a day (the cap is checked against
  a listing cached for up to 60 seconds).
- `GET /v1/export` (Bearer `EXPORT_TOKEN`): every stored report, pulled by `.github/workflows/community-data.yml`.

Deploys with the site (`.github/workflows/site-pages.yml`). Secrets: `SALT` and `EXPORT_TOKEN` on the Pages
project, and the matching `COLLECTOR_TOKEN` Actions secret. Tests: `node --test test/worker.test.mjs`.

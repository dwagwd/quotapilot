# AI Quota Watch anonymous collector

A Cloudflare Worker that receives `quotapilot share` reports (and the site's report form) without any account.

- `POST /v1/report` `{install, reports[]}`: keeps only known plain-text fields, stores them for 35 days under
  `anon-<HMAC(SALT, install id)>`. The install id, IP address and GitHub account are never stored.
- Limits: 20 KB per request, 30 reports, 3 submissions per computer and 20 per IP address per day
  (counters keyed by `HMAC(SALT, ip + day)`, expiring after a day).
- `GET /v1/export` (Bearer `EXPORT_TOKEN`): every stored report, pulled by `.github/workflows/community-data.yml`.

Deploy: `npx wrangler deploy`, then set the `SALT` and `EXPORT_TOKEN` secrets (`wrangler secret put`) and
the matching `COLLECTOR_TOKEN` Actions secret. Tests: `node --test test/worker.test.mjs`.

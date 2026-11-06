# AI Quota Watch on X

Account kit and posting setup. Nothing here posts by itself.

## Profile

- **Name:** AI Quota Watch
- **Handle (pick the first free one):** @aiquotawatch, @ai_quota_watch, @aiquota_watch
- **Bio (160 max):** How much AI do you actually get? ChatGPT, Claude, Gemini and Grok plan limits, Codex resets and API cost for your workload. Every number sourced and dated.
- **Website:** https://aiquotawatch.pages.dev/
- **Avatar:** `avatar.png` (400×400) · **Header:** `banner.png` (1500×500, text sits right of the avatar)
- **Pinned post:** `node site/scripts/x-post.mjs --pinned`

## What gets posted

`site/scripts/x-post.mjs` reads the same files the site shows (`site/data/resets.json`, `site/data/changes.json`):

- a new Codex reset or banked reset card, with the vendor's post as the source;
- a new price or limit change, labelled "Reported, not confirmed" when it is not on an official page;
- at most 3 posts per run, only items from the last 3 days (older history is marked seen, never dumped).

Every post links back to the matching section of the site. No investment or trading content.

## Setup (needs the account owner)

1. Create the X account and set the profile above.
2. On https://developer.x.com create a project and app with **Read and write** permission (the free tier allows posting), then generate the API key/secret and the access token/secret for the account.
3. Store them in the keychain (or export as env vars):

   ```bash
   security add-generic-password -a "$USER" -s AQW_X_API_KEY -w
   security add-generic-password -a "$USER" -s AQW_X_API_SECRET -w
   security add-generic-password -a "$USER" -s AQW_X_ACCESS_TOKEN -w
   security add-generic-password -a "$USER" -s AQW_X_ACCESS_SECRET -w
   ```

4. Mark existing history as already posted, preview, then post:

   ```bash
   node site/scripts/x-post.mjs --mark-seen   # only on the very first run
   node site/scripts/x-post.mjs               # preview
   node site/scripts/x-post.mjs --send
   ```

5. Optional: `com.aiquotawatch.x-post.plist` runs `--send` every 30 minutes. Install only once posting is approved:

   ```bash
   cp marketing/x/com.aiquotawatch.x-post.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aiquotawatch.x-post.plist
   ```

Posts go out when the reset ledger or change log gets a new entry, so the daily data update is what drives the account.

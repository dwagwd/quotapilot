#!/bin/bash
# Turns on every sponsor entry point once a payout-capable page exists:
#   scripts/set-sponsor.sh https://polar.sh/<org>   or   https://ko-fi.com/<name>
# Sets site/assets/config.js (nav, hero, support card, footer, generated pages), the app's About menu, .github/FUNDING.yml (the GitHub
# "Sponsor" button) and the sponsor line in both READMEs, then rebuilds the generated pages and runs the site tests.
set -euo pipefail
URL="${1:-}"
[[ "$URL" =~ ^https://(polar\.sh|ko-fi\.com|github\.com/sponsors)/[A-Za-z0-9_.-]+/?$ ]] || {
  echo "usage: $0 https://polar.sh/<org> | https://ko-fi.com/<name> | https://github.com/sponsors/<user>"; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${URL%/}"; NAME="${NAME##*/}"
python3 - "$ROOT" "$URL" "$NAME" <<'PY'
import pathlib, re, sys
root, url, name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
cfg = root / "site/assets/config.js"
s = cfg.read_text()
s2 = re.sub(r'sponsor:\s*\{\s*url:\s*"[^"]*"', f'sponsor: {{ url: "{url}"', s, count=1)
assert s2 != s or url in s, "sponsor url not found in config.js"
cfg.write_text(s2)
links = root / "Sources/UsageCore/ProjectLinks.swift"
t = links.read_text()
t2 = re.sub(r'static let sponsorAddress = "[^"]*"', f'static let sponsorAddress = "{url}"', t, count=1)
assert t2 != t or url in t, "sponsorAddress not found in ProjectLinks.swift"
links.write_text(t2)
if "polar.sh" in url: funding = f"polar: {name}\n"
elif "ko-fi.com" in url: funding = f"ko_fi: {name}\n"
else: funding = f"github: {name}\n"
(root / ".github/FUNDING.yml").write_text("# Shown as the Sponsor button on GitHub.\n" + funding)
lines = {"README.md": f"**Like it? [Sponsor QuotaPilot]({url})**: it keeps the app free and AI Quota Watch's sources checked.",
         "README.zh-TW.md": f"**覺得有用？[贊助 QuotaPilot]({url})**：讓 App 持續免費、AI Quota Watch 的資料持續查證。"}
for f, line in lines.items():
    p = root / f; t = p.read_text()
    t = re.sub(r"<!-- sponsor:start -->.*?<!-- sponsor:end -->", f"<!-- sponsor:start -->{line}<!-- sponsor:end -->", t, flags=re.S)
    p.write_text(t)
PY
cd "$ROOT/site" && node scripts/build-pages.mjs >/dev/null && npm test --silent | tail -2
echo "Sponsor links point at $URL. Review with git diff, then commit."

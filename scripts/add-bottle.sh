#!/usr/bin/env bash
# Writes the bottle block for a published release into Formula/quotapilot.rb, so Homebrew downloads the
# prebuilt package instead of compiling. Run it after the Release workflow for the tag has finished:
#   scripts/add-bottle.sh vX.Y.Z            (downloads quotapilot-bottle.json from the GitHub release)
#   scripts/add-bottle.sh vX.Y.Z file.json  (uses a local copy)
# Then run ./scripts/check.sh and commit the formula (see docs/releasing.md).
set -euo pipefail
if [ "$#" -lt 1 ] || [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/add-bottle.sh vX.Y.Z [quotapilot-bottle.json]" >&2
  exit 2
fi
tag="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
json="${2:-}"
if [ -z "$json" ]; then
  json="$(mktemp)"
  curl -fsSL --max-time 60 "https://github.com/dwagwd/quotapilot/releases/download/${tag}/quotapilot-bottle.json" -o "$json" \
    || { echo "No quotapilot-bottle.json on release ${tag} yet; wait for the Release workflow." >&2; exit 1; }
fi
python3 "$root/scripts/bottle_block.py" "$root/Formula/quotapilot.rb" "$tag" "$json"
echo "Added the ${tag} bottle to Formula/quotapilot.rb."

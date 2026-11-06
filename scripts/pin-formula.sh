#!/usr/bin/env bash
# Pin Formula/quotapilot.rb to a release tag and the commit that tag points at.
# Usage: scripts/pin-formula.sh vX.Y.Z
# Run it AFTER creating the tag, then commit the result (see docs/releasing.md).
set -euo pipefail

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/pin-formula.sh vX.Y.Z" >&2
  exit 2
fi
tag="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"

if ! commit="$(git -C "$root" rev-parse --verify --quiet "refs/tags/${tag}^{commit}")"; then
  echo "Tag ${tag} does not exist in this repository; create it first." >&2
  exit 1
fi

python3 - "$root/Formula/quotapilot.rb" "$tag" "$commit" <<'PY'
import re
import sys

path, tag, commit = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
pattern = re.compile(r'(url "[^"]+", )tag: "[^"]*"(, revision: "[^"]*")?')
new, count = pattern.subn(lambda m: f'{m.group(1)}tag: "{tag}", revision: "{commit}"', text)
if count != 1:
    sys.exit("Could not find the formula's url line with tag:")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new)
PY

echo "Pinned Formula/quotapilot.rb to ${tag} (${commit})."

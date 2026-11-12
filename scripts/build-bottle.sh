#!/bin/bash
# Builds the Homebrew bottle (prebuilt package) for the checked-out commit and proves it installs.
# Meant for GitHub's macOS runners: it installs QuotaPilot into Homebrew, so do not run it on a Mac
# that already has QuotaPilot from Homebrew. Nothing is signed with a personal identity; the app is
# ad-hoc signed on the runner, and Homebrew pours bottles without the download quarantine flag.
# Usage: scripts/build-bottle.sh <root-url> <out-dir>
#   root-url  where the bottle will be downloaded from, e.g.
#             https://github.com/dwagwd/quotapilot/releases/download/v1.2.3
# Writes to out-dir: the bottle under the name Homebrew downloads (single dash) and quotapilot-bottle.json.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <root-url> <out-dir>" >&2; exit 2; }
ROOT_URL="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$2"; OUT="$(cd "$2" && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_INSTALL_CLEANUP=1

# Same tap name users have, so the bottle records the formula's real full name.
TAP="$(brew --repository)/Library/Taps/dwagwd/homebrew-quotapilot"
[ -d "$TAP" ] || brew tap-new --no-git dwagwd/quotapilot >/dev/null
# Build exactly this commit: point the formula at the checkout and drop any bottle block of an earlier release.
python3 - "$ROOT/Formula/quotapilot.rb" "$TAP/Formula/quotapilot.rb" "$ROOT" "$COMMIT" "$VERSION" <<'PY'
import re, sys
src, dst, root, commit, version = sys.argv[1:]
text = open(src, encoding="utf-8").read()
text, n = re.subn(r'^  url .*$', f'  url "file://{root}", using: :git, revision: "{commit}"\n  version "{version}"', text, count=1, flags=re.M)
assert n == 1, "formula url line not found"
text = re.sub(r'^  bottle do\n.*?^  end\n\n?', '', text, flags=re.M | re.S)
open(dst, "w", encoding="utf-8").write(text)
PY

brew install --build-bottle --verbose dwagwd/quotapilot/quotapilot
WORK="$(mktemp -d)"; cd "$WORK"
brew bottle --json --no-rebuild --root-url "$ROOT_URL" dwagwd/quotapilot/quotapilot
LOCAL="$(ls quotapilot--*.bottle.tar.gz)"
JSON="$(ls quotapilot--*.bottle.json)"

# Prove the bottle works the way users get it: remove the source build and pour the bottle.
brew uninstall dwagwd/quotapilot/quotapilot
brew install "./$LOCAL" 2>&1 | tee pour.log
grep -q "Pouring" pour.log || { echo "error: Homebrew did not pour the bottle" >&2; exit 1; }
quotapilot version | grep -q "$VERSION" || { echo "error: poured CLI is not version $VERSION" >&2; exit 1; }
APP="$(brew --prefix quotapilot)/QuotaPilot.app"
codesign --verify --deep --strict "$APP"
# No build-machine paths in what users run (the runner's own home is not personal data, but the checkout path must not leak in).
if LC_ALL=C grep -a -q -F "$ROOT" "$APP/Contents/MacOS/QuotaPilot" "$APP/Contents/Helpers/quotapilot"; then
  echo "error: poured binaries contain the build path" >&2; exit 1
fi

# Homebrew names the local file name--version…; downloads use name-version… (the "filename" in the JSON).
cp "$LOCAL" "$OUT/${LOCAL/--/-}"
cp "$JSON" "$OUT/quotapilot-bottle.json"
echo "Bottle: $OUT/${LOCAL/--/-}"

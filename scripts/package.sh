#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PLUGIN_ROOT/scripts/build.sh"
python3 "$PLUGIN_ROOT/scripts/check-release.py"
DIST_DIR="${QUOTAPILOT_DIST_DIR:-$HOME/Library/Caches/QuotaPilot/dist}"
VERSION="$(cat "$PLUGIN_ROOT/VERSION")"
APP="$DIST_DIR/QuotaPilot.app"
ARCH="$(uname -m)"
if [ "${QUOTAPILOT_UNIVERSAL:-0}" = "1" ]; then ARCH="universal"; fi
codesign --verify --strict "$APP"
APP_ZIP="$DIST_DIR/QuotaPilot-$VERSION-macos-$ARCH.zip"
# Optional notarization: QUOTAPILOT_NOTARY_PROFILE names a profile saved with
# `xcrun notarytool store-credentials`. Requires a Developer ID signed build.
if [ -n "${QUOTAPILOT_NOTARY_PROFILE:-}" ]; then
  if [ -z "${QUOTAPILOT_SIGN_IDENTITY:-}" ]; then
    echo "QUOTAPILOT_NOTARY_PROFILE needs QUOTAPILOT_SIGN_IDENTITY (Developer ID Application)." >&2
    exit 1
  fi
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$QUOTAPILOT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$APP_ZIP"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
shasum -a 256 "$APP_ZIP"
python3 "$PLUGIN_ROOT/scripts/source-archive.py" "$DIST_DIR/QuotaPilot-$VERSION-source.zip"
echo "Packages: $DIST_DIR"

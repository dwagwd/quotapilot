#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PLUGIN_ROOT/scripts/build.sh"
DIST_DIR="${QUOTAPILOT_DIST_DIR:-$HOME/Library/Caches/QuotaPilot/dist}"
APP="$DIST_DIR/QuotaPilot.app"
mkdir -p "$HOME/Applications"
# Quit this app gracefully before replacing its executable.
if pgrep -x QuotaPilot >/dev/null; then
    "$APP/Contents/MacOS/QuotaPilot" --quit
    for attempt in {1..30}; do
        if ! pgrep -x QuotaPilot >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x QuotaPilot >/dev/null; then
        echo 'Please quit QuotaPilot before reinstalling.' >&2; exit 1
    fi
fi
# Replace the pre-rename app if it is still installed.
LEGACY="$HOME/Applications/Codex Usage Widget.app"
if pgrep -x CodexUsageWidget >/dev/null && [ -x "$LEGACY/Contents/MacOS/CodexUsageWidget" ]; then
    "$LEGACY/Contents/MacOS/CodexUsageWidget" --quit || true
    for attempt in {1..30}; do pgrep -x CodexUsageWidget >/dev/null || break; sleep 0.1; done
fi
if [ -d "$LEGACY" ] && ! pgrep -x CodexUsageWidget >/dev/null; then rm -rf "$LEGACY"; fi
# Replace instead of merging, so files removed from the bundle (and stale signatures) do not linger.
INSTALLED="$HOME/Applications/QuotaPilot.app"
STAGING="$HOME/Applications/.QuotaPilot.app.installing"
rm -rf "$STAGING"
ditto "$APP" "$STAGING"
rm -rf "$INSTALLED"
mv "$STAGING" "$INSTALLED"
echo "Installed: $HOME/Applications/QuotaPilot.app"

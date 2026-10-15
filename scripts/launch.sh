#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/QuotaPilot.app"
if [ ! -x "$APP/Contents/MacOS/QuotaPilot" ]; then
    "$PLUGIN_ROOT/scripts/build-install.sh"
fi
open "$APP"

#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GIT_CEILING_DIRECTORIES="$(dirname "$PLUGIN_ROOT")"
swift test --package-path "$PLUGIN_ROOT" --scratch-path "${QUOTAPILOT_TEST_CACHE:-$HOME/Library/Caches/QuotaPilot/tests}" --disable-index-store --jobs 2
python3 -m unittest discover -s "$PLUGIN_ROOT/scripts/tests"
python3 "$PLUGIN_ROOT/scripts/check-release.py"

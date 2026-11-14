#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GIT_CEILING_DIRECTORIES="$(dirname "$PLUGIN_ROOT")"
swift test --package-path "$PLUGIN_ROOT" --scratch-path "${QUOTAPILOT_TEST_CACHE:-$HOME/Library/Caches/QuotaPilot/tests}" --disable-index-store --jobs 2
python3 -m unittest discover -s "$PLUGIN_ROOT/scripts/tests"
python3 "$PLUGIN_ROOT/scripts/check-release.py"
# Website aggregation/i18n and collector tests (Node.js 20+). Skipped with a notice when Node.js is missing.
if command -v node >/dev/null 2>&1; then
  (cd "$PLUGIN_ROOT/site" && npm test --silent)
  node --test "$PLUGIN_ROOT/collector/test/worker.test.mjs" "$PLUGIN_ROOT/collector/test/d1store.test.mjs"
else
  echo "Node.js not found: skipped site/ and collector/ tests." >&2
fi

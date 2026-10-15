#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PLUGIN_ROOT"
# Keep SwiftPM from scanning an unrelated repository above this standalone package.
export GIT_CEILING_DIRECTORIES="$(dirname "$PLUGIN_ROOT")"
BUILD_CACHE="${CODEX_WIDGET_BUILD_CACHE:-$HOME/Library/Caches/CodexUsageWidget/build}"
DIST_DIR="${CODEX_WIDGET_DIST_DIR:-$HOME/Library/Caches/CodexUsageWidget/dist}"
APP_VERSION="$(cat "$PLUGIN_ROOT/VERSION")"
# CODEX_WIDGET_UNIVERSAL=1 builds one arm64 + x86_64 binary (needs Xcode, not only the CLT).
ARCH_FLAGS=()
if [ "${CODEX_WIDGET_UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build --scratch-path "$BUILD_CACHE" -c release --disable-index-store --jobs 2 ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build --scratch-path "$BUILD_CACHE" -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"
APP="$DIST_DIR/Codex Usage Widget.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexUsageWidget" "$APP/Contents/MacOS/CodexUsageWidget"
# Bundled so "Connect agents…" can install status-line bridges without a source checkout.
cp "$PLUGIN_ROOT/scripts/provider_bridge.py" "$PLUGIN_ROOT/scripts/setup-provider.py" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.usage-widget</string>
<key>CFBundleName</key><string>Codex Usage Widget</string>
<key>CFBundleDisplayName</key><string>Codex Usage Widget</string>
<key>CFBundleExecutable</key><string>CodexUsageWidget</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Ad-hoc by default. Set CODEX_WIDGET_SIGN_IDENTITY to a "Developer ID Application" identity
# to sign with the hardened runtime and a secure timestamp, as notarization requires.
if [ -n "${CODEX_WIDGET_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$CODEX_WIDGET_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built: $APP"

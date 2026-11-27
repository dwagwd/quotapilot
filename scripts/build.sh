#!/bin/bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PLUGIN_ROOT"
# Keep SwiftPM from scanning an unrelated repository above this standalone package.
export GIT_CEILING_DIRECTORIES="$(dirname "$PLUGIN_ROOT")"
BUILD_CACHE="${QUOTAPILOT_BUILD_CACHE:-$HOME/Library/Caches/QuotaPilot/build}"
DIST_DIR="${QUOTAPILOT_DIST_DIR:-$HOME/Library/Caches/QuotaPilot/dist}"
APP_VERSION="${QUOTAPILOT_APP_VERSION:-$(cat "$PLUGIN_ROOT/VERSION")}"  # override only to test updates
# QUOTAPILOT_UNIVERSAL=1 builds one arm64 + x86_64 binary (needs Xcode, not only the CLT).
ARCH_FLAGS=()
if [ "${QUOTAPILOT_UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
# Published binaries must not carry this machine's paths (user name, folder names): map the source and
# build folders to neutral names, and strip debug symbols, which otherwise point at the object files.
PREFIX_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PLUGIN_ROOT=quotapilot" -Xswiftc -file-prefix-map -Xswiftc "$BUILD_CACHE=build")
# Extra SwiftPM arguments, e.g. --disable-sandbox when Homebrew builds inside its own sandbox.
read -r -a EXTRA_ARGS <<< "${QUOTAPILOT_SWIFTPM_ARGS:-}"
swift build --scratch-path "$BUILD_CACHE" -c release --disable-index-store --jobs 2 ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "${PREFIX_FLAGS[@]}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build --scratch-path "$BUILD_CACHE" -c release --show-bin-path ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "${PREFIX_FLAGS[@]}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"
APP="$DIST_DIR/QuotaPilot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/QuotaPilotApp" "$APP/Contents/MacOS/QuotaPilot"
# The `quotapilot` command-line tool (status, share, ...). Homebrew links it onto PATH (see Formula/quotapilot.rb).
# It lives in Helpers because Contents/MacOS/quotapilot would collide with QuotaPilot on case-insensitive volumes.
cp "$BIN_DIR/quotapilot" "$APP/Contents/Helpers/quotapilot"
strip -S "$APP/Contents/MacOS/QuotaPilot" "$APP/Contents/Helpers/quotapilot"
for bin in "$APP/Contents/MacOS/QuotaPilot" "$APP/Contents/Helpers/quotapilot"; do
  if LC_ALL=C grep -a -q -E "$HOME|$PLUGIN_ROOT|$BUILD_CACHE" "$bin"; then
    echo "error: $bin still contains a local path; refusing to package it" >&2; exit 1
  fi
done
# Bundled so "Connect agents…" can install status-line bridges without a source checkout.
cp "$PLUGIN_ROOT/scripts/provider_bridge.py" "$PLUGIN_ROOT/scripts/setup-provider.py" "$APP/Contents/Resources/"
cp "$PLUGIN_ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.dwagwd.quotapilot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>QuotaPilot</string>
<key>CFBundleDisplayName</key><string>QuotaPilot</string>
<key>CFBundleExecutable</key><string>QuotaPilot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Ad-hoc by default. Set QUOTAPILOT_SIGN_IDENTITY to a "Developer ID Application" identity
# to sign with the hardened runtime and a secure timestamp, as notarization requires.
# Nested code is signed first so the app's signature seals it.
if [ -n "${QUOTAPILOT_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$QUOTAPILOT_SIGN_IDENTITY" "$APP/Contents/Helpers/quotapilot"
  codesign --force --options runtime --timestamp --sign "$QUOTAPILOT_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP/Contents/Helpers/quotapilot"
  codesign --force --sign - "$APP"
fi
echo "Built: $APP"

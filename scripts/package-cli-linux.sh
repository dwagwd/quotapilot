#!/bin/bash
# Build static Linux binaries of the quotapilot CLI from macOS.
# Needs a swift.org toolchain (not Xcode's) matching an installed Static Linux SDK, e.g.:
#   TOOLCHAINS=org.swift.624202602241a ./scripts/package-cli-linux.sh
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${QUOTAPILOT_DIST_DIR:-$HOME/Library/Caches/QuotaPilot/dist}"
VERSION="$(cat "$PLUGIN_ROOT/VERSION")"
mkdir -p "$DIST_DIR"
for arch in x86_64 aarch64; do
  CACHE="$HOME/Library/Caches/QuotaPilot/linux-$arch"
  xcrun --toolchain "${TOOLCHAINS:?set TOOLCHAINS to a swift.org toolchain}" swift build --package-path "$PLUGIN_ROOT" \
    --scratch-path "$CACHE" --swift-sdk "$arch-swift-linux-musl" -c release --product quotapilot -Xswiftc -gnone -Xlinker -s
  OUT="$DIST_DIR/quotapilot-$VERSION-linux-$arch"
  cp "$CACHE/$arch-swift-linux-musl/release/quotapilot" "$OUT"
  tar -C "$DIST_DIR" -czf "$OUT.tar.gz" "$(basename "$OUT")" && rm "$OUT"
  shasum -a 256 "$OUT.tar.gz"
done

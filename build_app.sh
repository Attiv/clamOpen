#!/bin/bash
# Build ClamOpen.app and 恢复内置屏.app using swiftc directly.
# (swift build via SPM is broken on this machine due to
#  a corrupted CommandLineTools installation — PackageDescription
#  module is missing. Use `xcode-select --install` to fix.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
TARGET="x86_64-apple-macos12.0"
BUILD_DIR="$ROOT/.build/release"

mkdir -p "$BUILD_DIR"

# ---- icons ----
if [[ ! -f "$ROOT/AppIcon.icns" || ! -f "$ROOT/RestoreIcon.icns" ]]; then
  echo "==> Generating icons ..."
  swift "$ROOT/make_icon.swift" "$ROOT"
  iconutil -c icns "$ROOT/AppIcon.iconset"     -o "$ROOT/AppIcon.icns"
  iconutil -c icns "$ROOT/RestoreIcon.iconset" -o "$ROOT/RestoreIcon.icns"
fi

# ---- compile ----
echo "==> Building ClamOpen ..."
swiftc -sdk "$SDK" -target "$TARGET" -O \
  -framework AppKit -framework CoreGraphics \
  -o "$BUILD_DIR/ClamOpen" \
  "$ROOT/Sources/ClamOpen/main.swift" \
  "$ROOT/Sources/ClamOpen/DisplayController.swift" \
  "$ROOT/Sources/ClamOpen/AppDelegate.swift" \
  "$ROOT/Sources/ClamOpen/PowerManager.swift"

echo "==> Building ClamRestore ..."
swiftc -sdk "$SDK" -target "$TARGET" -O \
  -framework CoreGraphics -framework Foundation \
  -o "$BUILD_DIR/ClamRestore" \
  "$ROOT/Sources/ClamRestore/main.swift"

# ---- assemble .app ----
make_app() {
  local exe="$1" appname="$2" plist="$3" icns="$4"
  local app="$ROOT/$appname.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BUILD_DIR/$exe" "$app/Contents/MacOS/$exe"
  cp "$plist" "$app/Contents/Info.plist"
  [[ -f "$ROOT/$icns" ]] && cp "$ROOT/$icns" "$app/Contents/Resources/$icns"
  codesign --force --sign - "$app" >/dev/null 2>&1 || echo "  (codesign skipped: $appname)"
  echo "  built: $app"
}

echo "==> Assembling app bundles ..."
make_app "ClamOpen"    "ClamOpen"   "$ROOT/Info.plist"         "AppIcon.icns"
make_app "ClamRestore" "恢复内置屏"  "$ROOT/Info-Restore.plist" "RestoreIcon.icns"

echo "==> Done."

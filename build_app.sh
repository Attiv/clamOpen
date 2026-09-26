#!/bin/bash
# 构建 ClamOpen.app（主程序）与 恢复内置屏.app（独立急救工具），并附带图标。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 1) 生成图标（缺失时）
if [[ ! -f "$ROOT/AppIcon.icns" || ! -f "$ROOT/RestoreIcon.icns" ]]; then
  echo "==> Generating icons ..."
  swift "$ROOT/make_icon.swift" "$ROOT"
  iconutil -c icns "$ROOT/AppIcon.iconset"     -o "$ROOT/AppIcon.icns"
  iconutil -c icns "$ROOT/RestoreIcon.iconset" -o "$ROOT/RestoreIcon.icns"
fi

# 2) 编译
echo "==> Building release binaries ..."
swift build --package-path "$ROOT" -c release
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

# 3) 组装 .app
make_app() {
  local exe="$1" appname="$2" plist="$3" icns="$4" l10n="$5"
  local app="$ROOT/$appname.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN_DIR/$exe" "$app/Contents/MacOS/$exe"
  cp "$plist" "$app/Contents/Info.plist"
  [[ -f "$ROOT/$icns" ]] && cp "$ROOT/$icns" "$app/Contents/Resources/$icns"
  # 本地化资源（en / zh-Hans 的 InfoPlist.strings，用于 Finder / Spotlight 显示名）
  [[ -d "$ROOT/Localization/$l10n" ]] && cp -R "$ROOT/Localization/$l10n/"*.lproj "$app/Contents/Resources/"
  codesign --force --sign - "$app" >/dev/null 2>&1 || echo "  (codesign skipped: $appname)"
  echo "  built: $app"
}

echo "==> Assembling app bundles ..."
make_app "ClamOpen"    "ClamOpen"   "$ROOT/Info.plist"         "AppIcon.icns"    "ClamOpen"
make_app "ClamRestore" "恢复内置屏"  "$ROOT/Info-Restore.plist" "RestoreIcon.icns" "ClamRestore"

echo "==> Done."

#!/bin/bash
# Requires a logged-in macOS GUI session; uses only fixture bundles and a fake app launcher.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
swiftc -I "$BIN/Modules" \
  "$ROOT/Sources/ClamOpen/ApplicationGPUWindowController.swift" \
  "$ROOT/Tests/ClamGPUWindowHarness/main.swift" \
  "$BIN/ClamCore.build/ApplicationGPU.swift.o" \
  "$BIN/ClamCore.build/ApplicationGPUBackend.swift.o" \
  "$BIN/ClamCore.build/GPUController.swift.o" \
  -o "$BIN/ClamGPUWindowHarness"
"$BIN/ClamGPUWindowHarness" "$BIN/application-gpu-window.png"

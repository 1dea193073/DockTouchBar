#!/bin/bash
# 离屏渲染“配对智能体”页成 PNG（默认 build/pairing-page.png），不打开真窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-settings/main.swift -o build/tools/render-settings
build/tools/render-settings "${1:-build/pairing-page.png}"

#!/bin/bash
# 验证真实 NSScrubber 的列表变化和滚动位置；不挂接 Touch Bar、不关闭用户应用。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" tools/verify-dock-list/main.swift -o build/tools/verify-dock-list
build/tools/verify-dock-list "$@"

#!/bin/bash
# 验证图标排列（仅运行模式下访达的位置和显示）、图标居中，以及切换模式时列表不会残留旧图标（重影）。
# 用生产的 DockBarController 和真正的 NSScrubber，只替换数据；不挂接 Touch Bar、不动用户的 App。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" tools/verify-dock-layout/main.swift -o build/tools/verify-dock-layout
build/tools/verify-dock-layout "$@"

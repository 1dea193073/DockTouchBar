#!/bin/bash
# 真实访达上验证垃圾桶：识别废纸篓窗口、双击最小化、长按关闭，且不碰访达的其他窗口。
# 会打开/关闭一个废纸篓窗口；需要运行它的终端有辅助功能权限。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" tools/verify-trash/main.swift -o build/tools/verify-trash
build/tools/verify-trash "$@"

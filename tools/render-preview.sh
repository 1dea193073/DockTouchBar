#!/bin/bash
# 离屏渲染 Touch Bar 上的 Dock，输出 PNG。改了图标布局、颜色之后用来看效果，
# 不用等 Touch Bar 亮着，也不会影响正在运行的 App。
# 用法：tools/render-preview.sh [输出路径]      默认 build/preview.png
#       PREVIEW_PRESS_INDEX=1 tools/render-preview.sh   第 2 个图标显示长按进度条
#       PREVIEW_DEMO=1 PREVIEW_FRAME=1 tools/render-preview.sh assets/touchbar.png   README 用的示意图（示例 App，带外框）
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/preview.png}"
mkdir -p build/tools "$(dirname "$OUT")"

SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-preview/main.swift -o build/tools/render-preview
build/tools/render-preview "$OUT"

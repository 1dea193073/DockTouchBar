#!/bin/bash
# 预览“AI 助手状态”在 Touch Bar 图标上的样子（字符雨、OK、屏幕外框）。
# 不需要 Touch Bar：用 App 自己的代码把 Dock 画在屏幕上的一个小窗口里，用 screencapture 按窗口截图，裁出前几个图标并放大。
# 示例图标里 Safari 和 Notes 在“工作中”，Messages 在“做完”。输出默认 build/agent-preview.png（用 Read 工具或预览打开看）。
# 用法：tools/preview-agent.sh [输出路径] [第几帧：几秒后截，默认 3.5]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/agent-preview.png}"
WAIT="${2:-3.5}"
mkdir -p build build/tools "$(dirname "$OUT")"

SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-preview/main.swift -o build/tools/render-preview

LOG="$(mktemp)"
PREVIEW_DEMO=1 PREVIEW_AGENT=1 PREVIEW_AGENT_APP="${PREVIEW_AGENT_APP:-}" PREVIEW_LIVE=1 PREVIEW_LIVE_SECONDS=10 build/tools/render-preview /dev/null >"$LOG" 2>&1 &
sleep "$WAIT"
WINDOW="$(grep -o 'WINDOW [0-9]*' "$LOG" | cut -d' ' -f2)"
[ -n "$WINDOW" ] || { echo "没有拿到预览窗口" >&2; cat "$LOG" >&2; exit 1; }
RAW="$(mktemp -t agent-preview).png"
screencapture -x -o -l "$WINDOW" "$RAW"
wait || true
# 窗口截图是 2 倍屏：裁出左边约 5 个图标，再放大 5 倍，像素才看得清。
sips -c 60 420 --cropOffset 0 480 "$RAW" --out "$RAW" >/dev/null
sips -z 300 2100 "$RAW" --out "$OUT" >/dev/null
rm -f "$RAW" "$LOG"
echo "Wrote $OUT"

#!/bin/bash
# 录 README 用的 Vibecoding 版动图 assets/vibe-agents.gif：几个编程工具的图标依次 空闲 → 工作中（字符雨）→ 做完（OK）。
# 用 App 自己的代码在屏幕上画一个小窗口，screencapture 按窗口录像，再套上 Touch Bar 外框转成 GIF。
# 图标取自这台电脑上装着的 App；没装的会被跳过。可用环境变量 AGENT_APPS 换成别的（逗号分隔的 .app 路径）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools build/gifs assets

APPS=()
for app in ${AGENT_APPS:-/Applications/Claude.app,/Applications/ChatGPT.app,/Applications/Qoder.app,/Applications/WorkBuddy.app,/Applications/Antigravity.app}; do
    for one in ${app//,/ }; do [ -d "$one" ] && APPS+=("$one"); done
done
[ ${#APPS[@]} -gt 0 ] || { echo "一个都没找到，检查 AGENT_APPS" >&2; exit 1; }
LIST="$(IFS=,; echo "${APPS[*]}")"

SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-preview/main.swift -o build/tools/render-preview

LOG=build/gifs/agents.log
: > "$LOG"
# 时间线：1 秒空闲，之后工作中，到 4.4 秒做完；录 7 秒。
PREVIEW_DEMO=1 PREVIEW_LIVE=1 PREVIEW_LIVE_SECONDS=14 PREVIEW_AGENT_APPS="$LIST" \
    PREVIEW_AGENT_TIMELINE="1.2:working,4.6:done" build/tools/render-preview /dev/null > "$LOG" &
PID=$!
WIN=""
for _ in $(seq 1 60); do
    WIN="$(awk '/^WINDOW/ {print $2; exit}' "$LOG" 2>/dev/null || true)"
    [ -n "$WIN" ] && break
    sleep 0.15
done
[ -n "$WIN" ] || { kill "$PID" 2>/dev/null || true; echo "拿不到预览窗口" >&2; exit 1; }
sleep 0.4
screencapture -v -V 7.5 -l "$WIN" build/gifs/agents.mov
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
python3 tools/compose-gifs.py agents

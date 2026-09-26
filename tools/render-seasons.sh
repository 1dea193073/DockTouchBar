#!/bin/bash
# 生成 README 用的 Touch Bar 截图：四个季节的“长按退出”各一张（整条 Touch Bar，带圆角外框），再上下拼成 seasons.png；
# 顺便重画一张平时状态的 touchbar.png。
# 长按提示是在真实窗口里跑起来的（动画、粒子、会跑的小角色都是真的），再用 screencapture 按窗口编号截下来，
# 所以要在有桌面的登录会话里运行，并且给运行它的终端（或 Claude）“屏幕录制”权限。
# 图里的文字默认是英文（README 主页是英文），要中文：PREVIEW_LANG=zh tools/render-seasons.sh
# 用法：tools/render-seasons.sh [输出目录]      默认 assets
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-assets}"
TOOL=build/tools/render-preview
export PREVIEW_LANG="${PREVIEW_LANG:-en}"
mkdir -p build/tools build/seasons "$OUT"

SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-preview/main.swift -o "$TOOL"

FRAMES=()
for season in spring summer autumn winter; do
    LOG="build/seasons/$season.log"
    : > "$LOG"
    PREVIEW_LIVE=1 PREVIEW_LIVE_SECONDS=8 PREVIEW_DEMO=1 PREVIEW_THEME="$season" PREVIEW_PRESS_INDEX=2 "$TOOL" > "$LOG" &
    PID=$!
    WINDOW=""
    for _ in $(seq 1 50); do
        WINDOW="$(awk '/^WINDOW/ {print $2; exit}' "$LOG")"
        [ -n "$WINDOW" ] && break
        sleep 0.2
    done
    if [ -z "$WINDOW" ]; then kill "$PID" 2>/dev/null || true; echo "$season：窗口没有出现" >&2; exit 1; fi
    # 倒计时 3 秒，走到一半时截图。
    sleep 1.6
    screencapture -x -l "$WINDOW" "build/seasons/$season-raw.png"
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    "$TOOL" --frame "build/seasons/$season-raw.png" "$OUT/season-$season.png"
    FRAMES+=("$OUT/season-$season.png")
done

"$TOOL" --stack "$OUT/seasons.png" "${FRAMES[@]}"
PREVIEW_DEMO=1 PREVIEW_FRAME=1 "$TOOL" "$OUT/touchbar.png"

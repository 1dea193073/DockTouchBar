#!/bin/bash
# 录制并生成 README 顶部展示用的高画质 GIF 动画：
# 1. assets/touchbar-idle.gif    (平时空闲状态：右上角状态圆点 + 咖啡杯白烟袅袅飘动)
# 2. assets/touchbar-spring.gif  (春：小狗奔跑、花瓣飘落)
# 3. assets/touchbar-summer.gif  (夏：帆船航行、浪花飞溅)
# 4. assets/touchbar-autumn.gif  (秋：狐狸奔跑、落叶纷飞)
# 5. assets/touchbar-winter.gif  (冬：雪橇滑行、雪花漫天)
# 6. assets/touchbar-seasons.gif (四季合辑动图)
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/tools build/gifs assets
TOOL="build/tools/render-preview"

# 确保最新代码编译
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc -O "${SOURCES[@]}" tools/render-preview/main.swift -o "$TOOL"

record_theme() {
    local name="$1"
    local theme="$2"
    local press_index="$3"
    local duration="$4"
    local mov="build/gifs/${name}.mov"
    local log="build/gifs/${name}.log"

    echo "==> 录制 $name ($theme)..."
    : > "$log"
    if [ -n "$press_index" ]; then
        PREVIEW_LIVE=1 PREVIEW_LIVE_SECONDS=8 PREVIEW_DEMO=1 PREVIEW_THEME="$theme" PREVIEW_PRESS_INDEX="$press_index" "$TOOL" > "$log" &
    else
        PREVIEW_LIVE=1 PREVIEW_LIVE_SECONDS=8 PREVIEW_DEMO=1 "$TOOL" > "$log" &
    fi
    local pid=$!

    local win=""
    for _ in $(seq 1 40); do
        win="$(awk '/^WINDOW/ {print $2; exit}' "$log" 2>/dev/null || true)"
        [ -n "$win" ] && break
        sleep 0.15
    done

    if [ -z "$win" ]; then
        kill "$pid" 2>/dev/null || true
        echo "错误：无法获取窗口" >&2
        return 1
    fi

    # 稍微等动画稳定开始
    sleep 0.6
    screencapture -v -V "$duration" -l "$win" "$mov"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "完成录制: $mov"
}

# 1. 录制空闲状态 (2.4 秒 = 2 个完整咖啡杯蒸汽循环)
record_theme "idle" "spring" "" 2.4

# 2. 录制四个季节 (长按 Messages, 2.5 秒)
record_theme "spring" "spring" 2 2.5
record_theme "summer" "summer" 2 2.5
record_theme "autumn" "autumn" 2 2.5
record_theme "winter" "winter" 2 2.5

echo "==> 转换并添加 Touch Bar 圆角外框生成 GIF..."
python3 tools/compose-gifs.py

echo "所有 GIF 生成完毕！"

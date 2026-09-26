#!/bin/bash
# 连点压力测试：在两个窗口分别在不同桌面的 App 之间来回快速点击，看最后一次点击之后是否真的切到了目标。
# 会真的切换你的桌面和前台 App（走的是和 Touch Bar 点击完全相同的 AppSwitcher.switchTo），
# 所以只在你 8 秒没动键盘鼠标时才开始，测试中一有键鼠输入就中止，测完切回起点。
# 用法：tools/stress-switch.sh <App A 的 bundle id> <App B 的 bundle id> [点击间隔毫秒 ...]
#   要求：A 和 B 的窗口在不同的桌面上，并且你现在停留在 A 所在的桌面。
#   例：tools/stress-switch.sh com.anthropic.claudefordesktop com.google.Chrome 400 250 150
# 每个间隔测 4 轮（环境变量 TRIALS 可改），每轮依次点 B、A、B、A、B，最后应该停在 B 的桌面上。
# 一轮之中有过键盘鼠标输入，这一轮就作废、不记录；被打断时已记录的干净轮次仍会显示。
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 2 ] || { sed -n '2,10p' "$0"; exit 1; }
mkdir -p build/tools
sed -e 's/private static func/static func/g' -e 's/private enum/enum/g' \
    Sources/DockTouchBar/AppSwitcher.swift > build/tools/AppSwitcherOpen.swift
swiftc -O build/tools/AppSwitcherOpen.swift Sources/DockTouchBar/DockModel.swift \
    tools/stress-switch/main.swift -o build/tools/stress-switch
build/tools/stress-switch "$@"

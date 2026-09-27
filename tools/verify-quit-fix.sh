#!/bin/bash
# 只读验证：打开、退出计算器（单窗口，没有确认框），核对 QuitPlanner 的 .quitApp 路径
# 是否正确判定为已退出，不会误判成 stillOpen。
# 用法：tools/verify-quit-fix.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/tools
sed -e 's/private static func/static func/g' -e 's/private enum/enum/g' \
    Sources/DockTouchBar/QuitPlanner.swift > build/tools/QuitPlannerOpen.swift
swiftc -O build/tools/QuitPlannerOpen.swift Sources/DockTouchBar/Localization.swift \
    tools/verify-quit-fix/main.swift -o build/tools/verify-quit-fix
build/tools/verify-quit-fix "$@"

#!/bin/bash
# 只读验证：真的打开、关闭 TextEdit 的两个测试窗口（自己建的临时文件），核对 QuitPlanner 的
# .closeWindow 路径是否正确判定为已关闭，不会误判成 stillOpen。不碰用户自己的窗口。
# 用法：tools/verify-close-fix.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/tools
# 把 QuitPlanner 里的 private 去掉，测试程序才能直接调用真实的判断逻辑。
sed -e 's/private static func/static func/g' -e 's/private enum/enum/g' \
    Sources/DockTouchBar/QuitPlanner.swift > build/tools/QuitPlannerOpen.swift
swiftc -O build/tools/QuitPlannerOpen.swift Sources/DockTouchBar/Localization.swift \
    tools/verify-close-fix/main.swift -o build/tools/verify-close-fix
build/tools/verify-close-fix "$@"

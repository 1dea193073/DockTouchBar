#!/bin/bash
# 只读诊断：点 Touch Bar 上某个 App 的图标，没有切到它窗口所在的桌面时，在“出问题的那一刻”运行它，
# 看程序是怎么判断这个 App 的窗口的：有哪些窗口、各在哪个桌面、哪些是真实窗口、最后会去提前哪一个。
# 不会切换桌面，也不会动任何窗口。
# 用法：tools/diagnose-switch.sh [bundle id ...]      默认查 Chrome 和访达
#       tools/diagnose-switch.sh com.apple.Safari
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- com.google.Chrome com.apple.finder

mkdir -p build/tools
# 把 AppSwitcher 里的 private 去掉，诊断程序才能直接调用它真实的判断逻辑（而不是另写一份）。
sed -e 's/private static func/static func/g' -e 's/private enum/enum/g' \
    Sources/DockTouchBar/AppSwitcher.swift > build/tools/AppSwitcherOpen.swift
swiftc -O build/tools/AppSwitcherOpen.swift Sources/DockTouchBar/DockModel.swift \
    tools/diagnose-switch/main.swift -o build/tools/diagnose-switch
build/tools/diagnose-switch "$@"

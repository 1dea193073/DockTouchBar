#!/bin/bash
# 编译生产逻辑的测试副本；替换系统 Touch Bar 桥和活动监视器，避免接管实体 Touch Bar。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools/safety
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    case "$(basename "$file")" in
        main.swift|TouchBarBridge.swift|SystemTouchBarActivityMonitor.swift) ;;
        DockBarController.swift|UpdateManager.swift|FinderWindowMonitor.swift)
            sed -e 's/private(set) //g' -e 's/private //g' "$file" > "build/tools/safety/$(basename "$file")"
            SOURCES+=("build/tools/safety/$(basename "$file")") ;;
        *) SOURCES+=("$file") ;;
    esac
done
swiftc "${SOURCES[@]}" tools/verify-safety/stubs.swift tools/verify-safety/main.swift -o build/tools/verify-safety
build/tools/verify-safety

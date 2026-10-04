#!/usr/bin/env bash
# 使用生产窗口入口测试真实窗口，独立以 WindowServer 几何读回验收，结束后恢复原布局。
# 运行时会暂时激活和移动 Finder / Chrome / 系统设置；请不要同时操作这些窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
GROUP="${1:-all}"
# 可选第二个参数 --strict-motion：额外要求受限窗口无横向往返；默认只验收几何与切换。
MOTION="${2:-}"
LABEL="regression-$(date +%Y%m%d-%H%M%S)"
mkdir -p build/tools build/diagnostics/window-regression
swiftc Sources/DockTouchBar/WindowPlacer.swift tools/verify-window-placement/main.swift -o build/tools/verify-window-placement
build/tools/verify-window-placement "$LABEL" "$GROUP" "$MOTION" | tee "build/diagnostics/window-regression/$LABEL-$GROUP.log"

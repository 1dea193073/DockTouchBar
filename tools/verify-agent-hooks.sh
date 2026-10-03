#!/bin/bash
# 验证 AI 助手接入：hook 安装/卸载（保留原配置、坏文件不动、旧脚本迁移）和事件状态机。全程在临时目录里，不碰真实配置。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" tools/verify-agent-hooks/main.swift -o build/tools/verify-agent-hooks
build/tools/verify-agent-hooks "$@"

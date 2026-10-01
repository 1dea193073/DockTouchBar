#!/bin/bash
# 读取真实系统进程，用生产监视器验证残留 agent 与恢复；不挂接 Touch Bar、不结束截图进程。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools/capture-monitor
sed 's/private //g' Sources/DockTouchBar/SystemTouchBarActivityMonitor.swift > build/tools/capture-monitor/Monitor.swift
swiftc build/tools/capture-monitor/Monitor.swift tools/verify-capture-monitor/main.swift -o build/tools/verify-capture-monitor
build/tools/verify-capture-monitor

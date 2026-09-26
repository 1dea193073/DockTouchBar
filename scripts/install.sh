#!/bin/bash
# 编译 → 装到 /Applications → 启动（会先关掉正在运行的旧版本）
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
pkill -x DockTouchBar 2>/dev/null || true
rm -rf /Applications/DockTouchBar.app
cp -R build/DockTouchBar.app /Applications/
open /Applications/DockTouchBar.app
echo "Installed /Applications/DockTouchBar.app"

#!/bin/bash
# 编译 → 装到 /Applications → 启动（会先关掉正在运行的旧版本）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DockTouchBar"
BUILD_APP="build/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

scripts/build.sh
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" /Applications/
# 正式安装完成后，中间 .app 不应继续作为第二个 LaunchServices/Spotlight 候选项存在。
"$LSREGISTER" -u "$BUILD_APP" 2>/dev/null || true
rm -rf "$BUILD_APP"
open "$INSTALL_APP"
echo "Installed $INSTALL_APP"

#!/bin/bash
# 使用生产双击处理，验证本工具自己创建的窗口，不动用户窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/tools/VerifyMinimize.app"
mkdir -p "$APP/Contents/MacOS"
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc tools/verify-minimize-fixture/main.swift -o "$APP/Contents/MacOS/VerifyMinimize"
swiftc "${SOURCES[@]}" tools/verify-minimize/main.swift -o build/tools/verify-minimize-runner
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hooosberg.docktouchbar.verify-minimize</string>
<key>CFBundleName</key><string>VerifyMinimize</string>
<key>CFBundleExecutable</key><string>VerifyMinimize</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
STATE="build/tools/minimize-state.json"
rm -f "$STATE"
"$APP/Contents/MacOS/VerifyMinimize" "$STATE" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
build/tools/verify-minimize-runner "$PWD/$APP" "$STATE"

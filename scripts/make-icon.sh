#!/bin/bash
# 生成 Resources/AppIcon.icns（改了 make-icon.swift 的配色或图形后重新跑一次）
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/master.png"
ICONSET="$WORK/AppIcon.iconset"

swift scripts/make-icon.swift "$MASTER"
mkdir -p "$ICONSET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$MASTER" Resources/AppIcon-1024.png
echo "Wrote Resources/AppIcon.icns"

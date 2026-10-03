#!/bin/bash
# 验证多语言：源码里每一句界面文字，12 种语言都有译文、占位符齐全；运行时按所选语言真的换了文字。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
python3 tools/l10n/extract.py . > build/tools/l10n-strings.json
SOURCES=()
for file in Sources/DockTouchBar/*.swift; do
    [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" tools/verify-l10n/main.swift -o build/tools/verify-l10n
build/tools/verify-l10n build/tools/l10n-strings.json

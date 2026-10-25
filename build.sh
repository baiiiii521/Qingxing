#!/bin/zsh
# 清醒 Qingxing 构建脚本 —— 只需 CommandLineTools（swiftc），无需 Xcode 工程
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Qingxing.app"

echo "[1/5] 编译主程序..."
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    main.swift \
    -o "$APP/Contents/MacOS/Qingxing" \
    -framework AppKit -framework IOKit -framework ServiceManagement

echo "[2/5] 生成图标..."
swift gen_icon.swift
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "[3/5] 组装 .app..."
cp Info.plist "$APP/Contents/Info.plist"

echo "[4/5] Ad-hoc 签名..."
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "[5/5] 完成 ✅  $APP"

#!/bin/bash
# 版下の部品を marketing/screenshots/build/ に作る。
#
#   build/assets/symbols/manifest.js   SF Symbols（mask-image 用の data URI）
#   build/assets/icons/*.png           アプリのアイコン（この Mac に入っているものから）
#   build/meta.js                      フッターに出す版
#
# スクリーンショット（render.sh）とデモ動画（../demo/render.sh）が同じ部品を読む。
# 作り方を 2 か所に書くと、記号を足したときに片方だけ古くなるので、ここ 1 か所で作る。
# 必要なもの: Swift（Xcode の Command Line Tools）、アイコンを借りるアプリ（shots.js で使うもの）
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

mkdir -p build
swift export_assets.swift build/assets
cp "$ROOT/bundle/icon/AppIcon.iconset/icon_512x512@2x.png" build/assets/icons/appmixer.png

# フッターに出る版はアプリと同じく Info.plist から取る。
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/bundle/Info.plist")"
echo "window.META = { version: \"$version\" };" > build/meta.js

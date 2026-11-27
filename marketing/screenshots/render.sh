#!/bin/bash
# App Store 用スクリーンショットを書き出す。
#
#   marketing/screenshots/render.sh            全部（日本語・英語）
#   marketing/screenshots/render.sh 01-per-app-volume ja
#
# 出力: marketing/screenshots/build/<lang>/<id>.png（2880×1800、アルファ無し）
# ファイル名の番号順が App Store での並び順。
# 必要なもの: Google Chrome、Swift（Xcode の Command Line Tools）、
#             アイコンを借りるアプリ（shots.js で使うもの）
set -euo pipefail

cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
  echo "error: Google Chrome が見つかりません（CHROME=<実行ファイル> で指定できます）" >&2
  exit 1
fi

# 部品（SF Symbols・アプリのアイコン・版）。デモ動画（../demo/render.sh）と同じもの。
./assets.sh

if [ $# -ge 1 ]; then
  ids="$1"
else
  ids="$(grep -o 'id: "[^"]*"' shots.js | cut -d'"' -f2)"
fi
langs="${2:-ja en}"

for lang in $langs; do
  mkdir -p "build/$lang"
  for id in $ids; do
    out="$PWD/build/$lang/$id.png"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
      --force-device-scale-factor=2 --window-size=1440,900 \
      --virtual-time-budget=4000 --default-background-color=000000ff \
      --screenshot="$out" \
      "file://$PWD/index.html?shot=$id&lang=$lang" >/dev/null 2>&1

    # App Store Connect の Mac 用の大きさ（16:10 の最大）で、アルファ無しであること。
    # アルファ付きの画像はアップロードで弾かれることがある。
    info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$out" | awk '/pixel|hasAlpha/ { printf "%s ", $2 }')"
    if [ "$info" != "2880 1800 no " ]; then
      echo "error: $out が 2880×1800・アルファ無しになっていません（$info）" >&2
      exit 1
    fi
    echo "$lang/$id.png"
  done
done

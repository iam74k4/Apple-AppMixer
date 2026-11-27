#!/bin/bash
# AstLog（astlog.dev）に載せるデモ動画を書き出す。
#
#   marketing/demo/render.sh
#
# 出力: marketing/demo/build/appmixer-demo.mp4（1440×900・60fps・H.264・音なし）
# 必要なもの: Google Chrome、Swift（Xcode の Command Line Tools）、Node.js 22 以降、
#             アイコンを借りるアプリ（Google Chrome・FaceTime・ミュージック）
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
export CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
  echo "error: Google Chrome が見つかりません（CHROME=<実行ファイル> で指定できます）" >&2
  exit 1
fi
if ! command -v node >/dev/null; then
  echo "error: Node.js が見つかりません（22 以降。コマを撮る render-frames.mjs が使います）" >&2
  exit 1
fi

# 1. 部品（SF Symbols・アプリのアイコン・版）。スクリーンショットと同じものを、同じ場所に作る。
../screenshots/assets.sh

# 2. 背景。全アプリ共通の絵（墨の無地と、描いたメニューバー）に、AppMixer のアイコンを置く。
#    閉じた状態と、ポップオーバーを開いた状態（アイコンの後ろに選択中の角丸）の 2 枚。
#    2 倍（2880×1800）で描き、版下が 1440×900 に縮めて敷く（video.html の background-size）。
#    1 倍で直に描くと、メニューバーのアイコン（14pt の slider.vertical.3）の細い線がつぶれて、
#    にじんだ塊に見える。
#    縮めるのに sips を使わない。sips は PNG の sRGB の印を gAMA（ガンマ 2.2）に書き換え、
#    Chrome がそのぶん色を変換して、地が #222226 より暗く（#1C1C21 に）写る。
mkdir -p build
swift "$ROOT/scripts/make-backdrop.swift" build/backdrop-idle@2x.png 2880 1800 --status-symbol slider.vertical.3
swift "$ROOT/scripts/make-backdrop.swift" build/backdrop-open@2x.png 2880 1800 --status-symbol slider.vertical.3 --status-selected

# 3. コマ。台本（video.js）の 0 秒から終わりまでを、1/60 秒ずつ PNG に撮る。
#    60fps にするのは、ポインタが速く動く所で跳ばないように（30fps では1コマに 25px ほど跳び、カクついて見えた）。
#    ポインタも図の指も時刻の式で決まるので、コマ数を変えても動きの速さと長さは変わらない。
node render-frames.mjs "file://$PWD/video.html?mode=video&lang=ja" build/frames 60

# 4. MP4。60fps でも 6Mbps なら 16 秒で 1MB ほどで、AstLog の上限（10MB）に十分収まる。
#    vidtool.swift は共通の道具の写しなので、警告が出ても、ここでは直さずに黙らせる。
swiftc -O -suppress-warnings "$ROOT/scripts/vidtool.swift" -o build/vidtool
build/vidtool encode build/frames build/appmixer-demo.mp4 60 6000000

# AstLog が受け取る動画は 10MB まで。台本を延ばしたりビットレートを上げたりして
# 超えたら、載せる段になって弾かれる前にここで止める。
bytes="$(stat -f %z build/appmixer-demo.mp4)"
if [ "$bytes" -gt 10000000 ]; then
  echo "error: build/appmixer-demo.mp4 が 10MB を超えています（$bytes バイト）。AstLog に載せられません" >&2
  exit 1
fi
echo "demo -> $PWD/build/appmixer-demo.mp4（$bytes バイト）"

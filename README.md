# AppMixer

![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-Proprietary-lightgrey)

**macOS でアプリケーションごとに音量を変える、メニューバー常駐のボリュームミキサー。**

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-dark.svg">
    <img src="docs/images/mixer-light.svg" width="420" alt="AppMixer のミキサー画面。マスター音量と、アプリごとの音量スライダー・レベルメーター・出力先が並んでいる">
  </picture>
</p>

## 機能

- アプリ別の音量・ミュート、ライブレベルメーター
- アプリ別の左右バランス（メーター上の区切りのつまみをドラッグ）
- 通知音・効果音などアプリに属さない音は「システム音」の 1 行にまとめて調整
- 出力デバイスごとに音量を記憶（デバイスを挿し替えると自動切り替え）
- アプリごとに出力先を振り分け（音楽はスピーカー、通話はヘッドフォンなど）
- 通話中は自動でメディア音量を下げる自動ダッキング
- マスター音量・全体ミュート、ログイン時に自動起動

## 動作要件

- macOS 14.4 以降
- 初回起動時に「システム音声録音」の許可が必要
  （システム設定 → プライバシーとセキュリティ → システム音声録音。マイクの許可ではありません）

## インストール

Mac App Store で公開予定（現在提出準備中）。それまでは [ソースからビルド](#ソースからビルドする)してください。

## 価格

買い切り（購読なし）。外部への情報送信は一切ありません。

## ソースからビルドする

Xcode 15.3 以降（macOS 14.4 SDK）が必要です。

```bash
git clone https://github.com/iam74k4/Apple-AppMixer.git
cd Apple-AppMixer
make run
```

自動テストは `make test` で走ります。

初回起動時に「システム音声録音」の許可を求められるので許可してください。

## 既知の制約

- 一部の出力デバイス（HDMI・AVアンプなど）では音量調整を行いません
- 増幅（100%超）はできません
- AppMixer を終了すると、音量を変えたアプリは元の音量に戻ります

## ライセンス

Copyright © 2026 iam74k4. All Rights Reserved.
詳細は [`LICENSE`](LICENSE) を参照してください。

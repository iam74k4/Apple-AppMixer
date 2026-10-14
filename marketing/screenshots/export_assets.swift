// スクリーンショットの部品（SF Symbols とアプリアイコン）を PNG に書き出す。
//
//   swift export_assets.swift <出力先>
//
// SF Symbols は黒一色で書き出し、HTML 側で mask-image として使って色を付ける。
// アプリアイコンはこの Mac にインストールされているものから取る。他社のアイコンを
// リポジトリへ入れないために、ここで毎回作る（出力先は .gitignore 済み）。

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift export_assets.swift <out-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: outDir.appendingPathComponent("symbols"), withIntermediateDirectories: true)
try fm.createDirectory(at: outDir.appendingPathComponent("icons"), withIntermediateDirectories: true)

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG に変換できません: \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - SF Symbols

// アプリ本体（ContentView / AppRowView）で使っているもの + メニューバーと機能一覧の飾り。
let symbols: [(name: String, weight: NSFont.Weight)] = [
    ("slider.vertical.3", .regular),
    ("hifispeaker", .regular),
    ("hifispeaker.fill", .regular),
    ("chevron.down", .semibold),
    ("speaker.wave.3.fill", .regular),
    ("speaker.wave.2.fill", .regular),
    ("speaker.slash.fill", .regular),
    ("magnifyingglass", .regular),
    ("gearshape", .regular),
    ("arrow.down.right.circle.fill", .regular),
    ("waveform.badge.mic", .regular),
    ("checkmark", .bold),
    // メニューバー
    ("wifi", .medium),
    ("battery.75percent", .regular),
    ("switch.2", .medium),
    // 機能一覧
    ("slider.horizontal.3", .regular),
    ("headphones", .regular),
    ("hifispeaker.2.fill", .regular),
    ("waveform", .regular),
    ("menubar.rectangle", .regular),
    ("phone.fill", .regular),
    ("arrow.triangle.2.circlepath", .regular),
    ("lock.shield", .regular),
    ("checkmark.seal.fill", .regular),
    ("mic.slash", .regular),
    ("arrow.left.arrow.right", .semibold),
    ("arrow.down", .semibold),
    // 左右バランスとシステム音
    ("arrow.left.and.right", .semibold),
    ("arrow.counterclockwise", .semibold),
    ("bell.fill", .regular),
]

// 大きめに描いて、表示側で縮める。拡大表示でも輪郭が甘くならないように。
let pointSize: CGFloat = 64
let scale: CGFloat = 4

// HTML から mask-image で読む。CSS のマスクは CORS で取りにいくため、file:// の
// ページからは別ファイルを読めない。data URI にして manifest.js へ埋め込む。
var manifest: [String: [String: Any]] = [:]

for (name, weight) in symbols {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let image = base.withSymbolConfiguration(config) else {
        FileHandle.standardError.write("warning: SF Symbol が見つかりません: \(name)\n".data(using: .utf8)!)
        continue
    }
    let size = image.size
    let rep = bitmap(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded())) {
        image.draw(in: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
    }
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG に変換できません: \(name)")
    }
    // 文字と並べるときの大きさ。point サイズあたりの幅と高さを残す。
    manifest[name] = [
        "w": Double(size.width / pointSize),
        "h": Double(size.height / pointSize),
        "src": "data:image/png;base64," + png.base64EncodedString(),
    ]
}

let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try ("window.SYMBOLS = " + String(data: manifestData, encoding: .utf8)! + ";\n")
    .write(to: outDir.appendingPathComponent("symbols/manifest.js"), atomically: true, encoding: .utf8)

// MARK: - アプリアイコン

let apps: [(key: String, path: String)] = [
    ("discord", "/Applications/Discord.app"),
    ("chrome", "/Applications/Google Chrome.app"),
    ("safari", "/Applications/Safari.app"),
    ("zoom", "/Applications/zoom.us.app"),
    ("music", "/System/Applications/Music.app"),
    ("facetime", "/System/Applications/FaceTime.app"),
    ("podcasts", "/System/Applications/Podcasts.app"),
    ("tv", "/System/Applications/TV.app"),
]

let iconPixels = 256
for (key, path) in apps {
    guard fm.fileExists(atPath: path) else {
        FileHandle.standardError.write("warning: \(path) が無いため \(key) のアイコンを作れません\n".data(using: .utf8)!)
        continue
    }
    // /Applications/Safari.app はシンボリックリンクのため、そのまま渡すと
    // エイリアスの矢印が付いたアイコンが返る。実体を辿ってから取る。
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let icon = NSWorkspace.shared.icon(forFile: resolved)
    // AppMixer の画面はダークモードで見せるので、アイコンも暗い外観で描く。
    // （macOS 26 ではアイコンの外観はシステム設定の「アイコンのスタイル」に従う）
    var rep: NSBitmapImageRep!
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        rep = bitmap(width: iconPixels, height: iconPixels) {
            icon.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels))
        }
    }
    writePNG(rep, to: outDir.appendingPathComponent("icons/\(key).png"))
}

// 「システム音」の行のアイコン。アプリ本体（AudioApp.icon）と同じく、この Mac の
// 機種アイコン（NSImage.computerName）を使う。
do {
    let icon = NSImage(named: NSImage.computerName)!
    var rep: NSBitmapImageRep!
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        rep = bitmap(width: iconPixels, height: iconPixels) {
            icon.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels))
        }
    }
    writePNG(rep, to: outDir.appendingPathComponent("icons/system.png"))
}

print("assets -> \(outDir.path)")

// 宣伝用のデモ動画・画像に敷く共通の背景（墨の無地とメニューバー）を PNG に書き出す。全アプリでこの1つを使う。
// 地は AstLog の墨（#222226。Web-AstLog の public/app.css の --ink、ロゴの素材の地 LOGO_COLORS.ground と同じ値）の無地。
// グラデーションも飾りも持たない（2026-11-11 に所有者が「シンプルに黒背景」と決めた。前は #1F1F21 → #0E0E0F の灰のグラデーション）。
// メニューバーの寸法と並びは前の背景と同じ。変えたのは地と帯の色だけ。
//
// 寸法は 1440×900 の絵を基準にし、幅に合わせて拡大する（上端にそろえる。16:10 より縦長の画面では、下も同じ墨）。
// 使い方: swift make-backdrop.swift <out.png> [<幅 px> <高さ px>] [--status-symbol <SF Symbol の名前> | --status-image <テンプレート画像> | --status-nonet] [--status-selected] [--no-menubar]
//   幅と高さを省くと、いまのメインの画面の大きさ（ピクセル）。デモ動画にはこれを使う。画像の合成（1440×900 の @2x）には 2880 1800
//   --status-symbol: アプリのメニューバーのアイコンが SF Symbols のとき（例: AppMixer は slider.vertical.3）
//   --status-image: アプリのメニューバーのアイコンの画像（PNG・PDF。形だけを使い、#F2F2F2 で塗る。高さ 18pt に収める）
//   --status-nonet: Nonet のアイコン（輪の 8 点と真ん中）
//   --status-selected: アイコンの後ろに、メニューを開いているときの明るい角丸を敷く（ポップオーバーを開いた絵のとき）
//   --no-menubar: メニューバーを描かない（iPhone のアプリ。端末の外には地だけを置く）
//   アイコンを指定しなければ、アプリのアイコンは描かない
import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = "使い方: swift make-backdrop.swift <out.png> [<幅 px> <高さ px>] [--status-symbol <名前> | --status-image <画像> | --status-nonet] [--status-selected] [--no-menubar]\n"
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }
var positional: [String] = []
var statusSymbol: String?
var statusImage: String?
var statusNonet = false
var statusSelected = false
var menubar = true
var rest = Array(CommandLine.arguments.dropFirst())[...]
while let arg = rest.popFirst() {
    switch arg {
    case "--status-symbol": guard let v = rest.popFirst() else { fail(usage) }; statusSymbol = v
    case "--status-image": guard let v = rest.popFirst() else { fail(usage) }; statusImage = (v as NSString).expandingTildeInPath
    case "--status-nonet": statusNonet = true
    case "--status-selected": statusSelected = true
    case "--no-menubar": menubar = false
    case "--no-status-icon": break
    default: positional.append(arg)
    }
}
guard positional.count == 1 || positional.count == 3, [statusSymbol != nil, statusImage != nil, statusNonet].filter({ $0 }).count <= 1 else { fail(usage) }
let size: (width: Int, height: Int)
if positional.count == 3 {
    guard let w = Int(positional[1]), let h = Int(positional[2]), w > 0, h > 0 else { fail(usage) }
    size = (w, h)
} else {
    // 主の画面（メニューバーのある画面。record-screen.swift が撮る画面）の大きさ。NSScreen.main はいま使っている画面で、
    // 外付けの画面から作ると、撮る画面と大きさが合わない
    guard let screen = NSScreen.screens.first else { fail("画面が見つかりません。幅と高さを指定してください") }
    size = (Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor))
}

let W: CGFloat = 1440, H: CGFloat = 900
let s = CGFloat(size.width) / W   // 基準の 1pt が何 px か
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size.height) - H * s)
ctx.scaleBy(x: s, y: s)
ctx.interpolationQuality = .high
func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a) }

// 地: 墨の無地（AstLog の --ink）
ctx.setFillColor(rgb(0x222226)); ctx.fill(CGRect(x: 0, y: H - CGFloat(size.height) / s, width: W, height: CGFloat(size.height) / s))

func text(_ string: String, font: CTFont, color: CGColor, rightEdge x: CGFloat, baseline y: CGFloat) {
    let attr = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attr))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: x - width, y: y)
    CTLineDraw(line, ctx)
}
// 画像の形を色で塗り、出す大きさの解像度で描く
func drawTinted(_ image: NSImage, center: CGPoint, box: CGSize, color: NSColor) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((box.width * s).rounded(.up)), pixelsHigh: Int((box.height * s).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = box
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(origin: .zero, size: box)
    image.draw(in: rect); color.set(); rect.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = rep.cgImage else { return }
    ctx.draw(cg, in: CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height))
}
func drawSymbol(_ name: String, center: CGPoint, size points: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = .white) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: points, weight: weight)) else {
        fail("SF Symbols に \(name) がありません")
    }
    drawTinted(image, center: center, box: image.size, color: color)
}

if menubar {
    // メニューバー（高さ 34。墨を少し沈めた帯 #1A1A1D。下に白 6% の 1pt の線）
    ctx.setFillColor(rgb(0x1A1A1D)); ctx.fill(CGRect(x: 0, y: H - 34, width: W, height: 34))
    ctx.setFillColor(rgb(0xFFFFFF, 0.06)); ctx.fill(CGRect(x: 0, y: H - 35, width: W, height: 1))
    // 右側（右から: 日付・コントロールセンター・Wi-Fi・電池・アプリのアイコン）
    let barY = H - 17
    text("11月7日(土) 9:41", font: CTFontCreateUIFontForLanguage(.system, 13, nil)!, color: rgb(0xF2F2F2), rightEdge: 1416, baseline: barY - 5)
    drawSymbol("switch.2", center: CGPoint(x: 1222, y: barY), size: 13)
    drawSymbol("wifi", center: CGPoint(x: 1172, y: barY), size: 13)
    drawSymbol("battery.100percent", center: CGPoint(x: 1116, y: barY), size: 15, weight: .regular)
    // アプリのメニューバーのアイコン（中心 x=1066）
    let iconCenter = CGPoint(x: 1066, y: barY)
    let iconColor = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255, alpha: 1)
    if statusSelected && (statusSymbol != nil || statusImage != nil || statusNonet) {
        ctx.setFillColor(rgb(0xFFFFFF, 0.16))
        ctx.addPath(CGPath(roundedRect: CGRect(x: iconCenter.x - 18, y: barY - 12, width: 36, height: 24), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
    }
    if let statusSymbol {
        drawSymbol(statusSymbol, center: iconCenter, size: 14, color: iconColor)
    } else if let statusImage {
        guard let image = NSImage(contentsOfFile: statusImage), image.size.height > 0 else { fail("画像を読めません: \(statusImage)") }
        let h: CGFloat = 18, w = h * image.size.width / image.size.height
        drawTinted(image, center: iconCenter, box: CGSize(width: w, height: h), color: iconColor)
    } else if statusNonet {
        // Nonet: 輪の 8 点と真ん中（Apple-Nonet の scripts/make-backdrop.swift と同じ形）
        ctx.setFillColor(rgb(0xF2F2F2))
        for slot in 0..<8 {
            let a = (-90 + 45 * Double(slot)) * .pi / 180
            let p = CGPoint(x: iconCenter.x + 6.3 * cos(a), y: iconCenter.y - 6.3 * sin(a))
            ctx.fillEllipse(in: CGRect(x: p.x - 1.7, y: p.y - 1.7, width: 3.4, height: 3.4))
        }
        ctx.fillEllipse(in: CGRect(x: iconCenter.x - 2.1, y: iconCenter.y - 2.1, width: 4.2, height: 4.2))
    }
}

let out = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fail("書き出せません: \(out.path)") }
print("wrote \(out.path) (\(size.width)×\(size.height))")

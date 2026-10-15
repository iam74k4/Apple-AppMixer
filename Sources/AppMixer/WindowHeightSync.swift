import AppKit
import SwiftUI

// MenuBarExtra(.window) のウインドウは、中身が伸びると付いてくるが、縮んでも
// 小さくならない。「全アプリ」を外す、設定を畳む、再生中のアプリが減るなどで
// 中身が短くなると、高いままの透明なウインドウの真ん中に中身が浮き、
// メニューバーから離れて宙に出ているように見える。
//
// 中身の実寸を見て、上端（メニューバー側）を固定したままウインドウの高さを
// 合わせる。伸びる向きは SwiftUI がやるので、ここは同じ値を書くだけになる。

/// 中身の高さにウインドウの高さを合わせる。中身の背景に置いて使う。
struct WindowHeightSync: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // 同じ更新の中で縮める。一拍おく（DispatchQueue.main.async）と、縮める前の
        // 背の高いウインドウの真ん中に中身が描かれた 1 コマが画面に出て、
        // ポップオーバーが一瞬消えたように見える。
        Self.fit(view.window, toContentHeight: contentHeight)
    }

    static func fit(_ window: NSWindow?, toContentHeight height: CGFloat) {
        guard let window, height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard let fitted = fitted(frame: window.frame, contentHeight: content.height, toContentHeight: height)
        else { return }
        window.setFrame(fitted, display: true, animate: false)
    }

    /// 上端を保ったまま、中身の高さぶんだけウインドウを縮めた（伸ばした）枠。
    /// 差が 1pt 未満なら nil（触らない）。
    static func fitted(frame: NSRect, contentHeight: CGFloat, toContentHeight target: CGFloat) -> NSRect? {
        let delta = target - contentHeight
        guard abs(delta) >= 1 else { return nil }
        // AppKit の座標は下が原点。高さを変えつつ上端を動かさないには、
        // 原点を差のぶんだけ逆向きにずらす。
        var fitted = frame
        fitted.origin.y -= delta
        fitted.size.height += delta
        return fitted
    }
}

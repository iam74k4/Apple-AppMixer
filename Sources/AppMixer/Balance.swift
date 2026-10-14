import Foundation

/// アプリごとの左右バランス。
///
/// 値は -1.0（左だけ）… 0（中央）… +1.0（右だけ）。macOS のサウンド設定の
/// 「バランス」と同じく、片側を絞るだけで反対側は持ち上げない。
/// 持ち上げると 100% を超えて歪むため。
enum Balance {

    /// 中央付近はここに吸着させる。つまみをドラッグで戻したとき、
    /// 目で見て真ん中でも数%ずれたままになるのを防ぐ。
    static let detent: Float = 0.06

    static func clamped(_ value: Float) -> Float {
        max(-1.0, min(1.0, value))
    }

    /// ドラッグで得た生の値を、範囲に収めて中央に吸着させる。
    static func snapped(_ value: Float) -> Float {
        let clamped = clamped(value)
        return abs(clamped) < detent ? 0 : clamped
    }

    /// ドラッグの開始時のバランスと横の移動量（pt）から、新しいバランスを求める。
    ///
    /// 押した位置へ飛ばさず、動かしたぶんだけ動かす。位置で決めると、
    /// ダブルクリックで中央に戻す操作の 1 回目のクリックや、スライダーを
    /// 狙って外したクリックで、押しただけでバランスが変わってしまう。
    static func dragged(from start: Float, translation: CGFloat, width: CGFloat) -> Float {
        guard width > 0 else { return snapped(start) }
        return snapped(start + Float(translation / width) * 2)
    }

    /// バランスからつまみの横位置（0...width）を求める。
    static func x(of value: Float, width: CGFloat) -> CGFloat {
        width * CGFloat((clamped(value) + 1) / 2)
    }

    /// 全体の音量とバランスから、左右それぞれに掛けるゲインを求める。
    static func channelGains(gain: Float, balance: Float) -> (left: Float, right: Float) {
        let b = clamped(balance)
        let left = b > 0 ? gain * (1 - b) : gain
        let right = b < 0 ? gain * (1 + b) : gain
        return (left, right)
    }

    /// 表示用の文言。「中央」「L 25%」「R 25%」。
    static func label(_ value: Float) -> String {
        let percent = Int((abs(clamped(value)) * 100).rounded())
        if percent == 0 { return localized("中央") }
        return value < 0 ? "L \(percent)%" : "R \(percent)%"
    }
}

import AppKit
import SwiftUI

// MenuBarExtra(.window) のウインドウは、閉じてもビューを捨てず、画面から
// 下げるだけ。onAppear / onDisappear は来ず、ビューに置いたタイマー
// （Timer.publish）も止まらない。macOS 26 では実際に、閉じたあとも 30fps で
// メーター更新が回り続けた。メーターのために張ったタップが一つも外れず、
// 音量を変えていないアプリまで常に AppMixer 経由で鳴っていた（CPU も常時
// 2〜4 割使っていた）。
//
// 開閉はウインドウの isVisible で判断する。macOS 26.6 で確かめたこと:
// - isVisible は開くと true、閉じると false になり、KVO で即座に届く。
//   ただし開く瞬間に true → false → true と数ミリ秒ばたつく。
// - occlusionState は開いていても .visible を含まない（0x2000 のまま）。
// - 状況メニューから開いてもアプリは前面に来ず、ウインドウは鍵にならない。
//   鍵の出入りや occlusion の通知には頼れない。
//
// 判断そのものは純粋な型に分けてテストする。

/// ポップオーバーが画面に出ているかの判断。
enum PanelVisibility {
    /// 閉じたと見なすまでに、見えない状態が続くべき時間。
    /// 開く瞬間のばたつき（数ミリ秒）を閉じたことにしない。
    static let closeDelay: TimeInterval = 0.2

    /// 表示状態の移り変わり。
    ///
    /// 同じ状態が何度届いても 1 回だけ伝える。見えなくなってから closeDelay
    /// のあいだは閉じたことにせず、そのあいだに見え直したら何も起きない。
    struct Tracker: Equatable {
        enum Transition: Equatable {
            case opened
            case closed
        }

        private(set) var isShowing = false
        /// 表示中に「見えない」が届いた時刻。閉じたのか、ばたついただけかの
        /// 見極め中だけ値を持つ。
        private(set) var hiddenSince: Date?

        /// 閉じたかの見極め中か。
        var isPendingClose: Bool { hiddenSince != nil }

        /// いまの見え方を受け取り、開いた／閉じたときだけ移り変わりを返す。
        mutating func update(
            visible: Bool,
            now: Date,
            closeDelay: TimeInterval = PanelVisibility.closeDelay
        ) -> Transition? {
            if visible {
                hiddenSince = nil
                guard !isShowing else { return nil }
                isShowing = true
                return .opened
            }
            guard isShowing else { return nil }
            guard let since = hiddenSince else {
                hiddenSince = now
                return nil
            }
            guard now.timeIntervalSince(since) >= closeDelay else { return nil }
            isShowing = false
            hiddenSince = nil
            return .closed
        }
    }
}

/// 置かれたウインドウの isVisible を見張り、変わったかもしれないときに今の値を
/// 知らせる。同じ値を何度も知らせることがある（受け手の Tracker がまとめる）。
/// 中身の背景に置いて使う。
struct PanelVisibilityReader: NSViewRepresentable {
    /// いまの isVisible を知らせる。
    let onChange: (Bool) -> Void
    /// いまの isVisible を問い合わせる手段を渡す。表示中の tick ごとに
    /// 確かめ直すために使う（通知を取りこぼしても閉じたことに気づける）。
    let onProbe: (@escaping () -> Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        // ビューが捨てられたら見えていないものとする。
        onProbe { [weak view] in view?.window?.isVisible ?? false }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var visibleObservation: NSKeyValueObservation?
        private var updateObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()

            guard let window else {
                report()
                return
            }
            // 開閉は isVisible の KVO で即座に届く。.initial で今の値も知らせる。
            visibleObservation = window.observe(\.isVisible, options: [.initial]) { [weak self] _, _ in
                // ウインドウの出し入れはメインスレッドで起きるが、KVO は変えた
                // スレッドでそのまま呼ばれる。念のためメインに載せ替えて読む。
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.report() }
                } else {
                    DispatchQueue.main.async { self?.report() }
                }
            }
            // isVisible の KVO は文書化された約束ではない。取りこぼしに備えて、
            // ウインドウが更新されるたびにも確かめる（開閉ごとに数回しか来ない）。
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            onChange?(window?.isVisible ?? false)
        }

        private func stopObserving() {
            visibleObservation = nil
            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
            }
            updateObserver = nil
        }

        deinit {
            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
            }
        }
    }
}

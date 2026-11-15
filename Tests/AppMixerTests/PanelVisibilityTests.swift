import XCTest
@testable import AppMixer

final class PanelVisibilityTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    func testTrackerStartsHidden() {
        let tracker = PanelVisibility.Tracker()
        XCTAssertFalse(tracker.isShowing)
        XCTAssertFalse(tracker.isPendingClose)
    }

    func testOpensAsSoonAsVisible() {
        var tracker = PanelVisibility.Tracker()
        // 開いたらすぐにメーターを回す。待つのは閉じるときだけ。
        XCTAssertEqual(tracker.update(visible: true, now: at(0)), .opened)
        XCTAssertTrue(tracker.isShowing)
    }

    func testRepeatedVisibleReportsOpenOnce() {
        var tracker = PanelVisibility.Tracker()
        XCTAssertEqual(tracker.update(visible: true, now: at(0)), .opened)
        // KVO と didUpdate と tick の三方から同じ状態が届く。2 回目以降は
        // 伝えない（伝えると開くたびに refresh が何重にも走る）。
        XCTAssertNil(tracker.update(visible: true, now: at(0.01)))
        XCTAssertNil(tracker.update(visible: true, now: at(0.04)))
        XCTAssertTrue(tracker.isShowing)
    }

    func testIgnoresHiddenBeforeFirstOpen() {
        // ウインドウに入った直後（まだ前に出ていない）の「見えない」は、
        // 閉じたことにしない。閉じる処理（タップの解放）を空振りさせない。
        var tracker = PanelVisibility.Tracker()
        XCTAssertNil(tracker.update(visible: false, now: at(0)))
        XCTAssertFalse(tracker.isPendingClose)
        XCTAssertNil(tracker.update(visible: false, now: at(1)))
        XCTAssertFalse(tracker.isShowing)
    }

    func testCloseWaitsForDelay() {
        var tracker = PanelVisibility.Tracker()
        _ = tracker.update(visible: true, now: at(0))

        // 見えなくなっても、すぐには閉じたことにしない。
        XCTAssertNil(tracker.update(visible: false, now: at(1), closeDelay: 0.2))
        XCTAssertTrue(tracker.isPendingClose)
        XCTAssertTrue(tracker.isShowing)
        XCTAssertNil(tracker.update(visible: false, now: at(1.1), closeDelay: 0.2))

        // 見えないまま待ち時間を過ぎたら閉じる。
        XCTAssertEqual(tracker.update(visible: false, now: at(1.25), closeDelay: 0.2), .closed)
        XCTAssertFalse(tracker.isShowing)
        XCTAssertFalse(tracker.isPendingClose)
    }

    func testFlickerWhileOpeningDoesNotClose() {
        // macOS 26.6 では、開く瞬間に isVisible が true → false → true と
        // 数ミリ秒ばたつく。ここで閉じると、開くたびにタップの解放と
        // 張り直しが走る。
        var tracker = PanelVisibility.Tracker()
        let reports: [(Bool, TimeInterval)] = [
            (true, 0), (false, 0.002), (true, 0.008), (false, 0.07), (true, 0.1),
        ]
        let transitions = reports.compactMap { tracker.update(visible: $0.0, now: at($0.1)) }
        XCTAssertEqual(transitions, [.opened])
        XCTAssertTrue(tracker.isShowing)
        XCTAssertFalse(tracker.isPendingClose)
    }

    func testVisibleAgainRestartsTheWait() {
        var tracker = PanelVisibility.Tracker()
        _ = tracker.update(visible: true, now: at(0))
        _ = tracker.update(visible: false, now: at(1), closeDelay: 0.2)
        _ = tracker.update(visible: true, now: at(1.05), closeDelay: 0.2)
        // 見え直したら待ちは振り出し。最初の「見えない」から数えない。
        XCTAssertNil(tracker.update(visible: false, now: at(1.1), closeDelay: 0.2))
        XCTAssertNil(tracker.update(visible: false, now: at(1.25), closeDelay: 0.2))
        XCTAssertEqual(tracker.update(visible: false, now: at(1.35), closeDelay: 0.2), .closed)
    }

    func testHiddenAfterCloseIsIgnored() {
        var tracker = PanelVisibility.Tracker()
        _ = tracker.update(visible: true, now: at(0))
        _ = tracker.update(visible: false, now: at(1), closeDelay: 0.2)
        XCTAssertEqual(tracker.update(visible: false, now: at(1.25), closeDelay: 0.2), .closed)
        // 閉じたあとに届く「見えない」で、閉じる処理を二度走らせない。
        XCTAssertNil(tracker.update(visible: false, now: at(1.3), closeDelay: 0.2))
        XCTAssertNil(tracker.update(visible: false, now: at(5), closeDelay: 0.2))
        XCTAssertFalse(tracker.isPendingClose)
    }

    func testReopenAfterClose() {
        var tracker = PanelVisibility.Tracker()
        let reports: [(Bool, TimeInterval)] = [
            (true, 0), (false, 2), (false, 2.25), (true, 5), (true, 5.03), (false, 7), (false, 7.25),
        ]
        let transitions = reports.compactMap {
            tracker.update(visible: $0.0, now: at($0.1), closeDelay: 0.2)
        }
        XCTAssertEqual(transitions, [.opened, .closed, .opened, .closed])
    }

    func testDefaultCloseDelayOutlastsOpeningFlicker() {
        // 実測のばたつきは開いてから 70ms ほど続いた。それより長く待つ。
        XCTAssertGreaterThan(PanelVisibility.closeDelay, 0.07)
        // 閉じてからタップを外すまでが延びすぎないようにする。
        XCTAssertLessThanOrEqual(PanelVisibility.closeDelay, 0.5)
    }
}

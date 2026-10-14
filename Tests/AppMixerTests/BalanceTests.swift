import XCTest
@testable import AppMixer

final class BalanceTests: XCTestCase {

    func testClamped() {
        XCTAssertEqual(Balance.clamped(-2), -1)
        XCTAssertEqual(Balance.clamped(2), 1)
        XCTAssertEqual(Balance.clamped(0.3), 0.3)
    }

    func testSnappedPullsNearCenterToZero() {
        XCTAssertEqual(Balance.snapped(0.03), 0)
        XCTAssertEqual(Balance.snapped(-0.059), 0)
        XCTAssertEqual(Balance.snapped(0.2), 0.2)
        XCTAssertEqual(Balance.snapped(-0.5), -0.5)
        XCTAssertEqual(Balance.snapped(3), 1)
    }

    func testDraggedMovesRelativeToStart() {
        let width: CGFloat = 200
        // 押しただけ（移動量 0）では変わらない。
        XCTAssertEqual(Balance.dragged(from: 0.3, translation: 0, width: width), 0.3)
        XCTAssertEqual(Balance.dragged(from: 0, translation: 0, width: width), 0)
        // 幅の半分動かすと 1.0 ぶん動く。
        XCTAssertEqual(Balance.dragged(from: 0, translation: 100, width: width), 1)
        XCTAssertEqual(Balance.dragged(from: 0, translation: -50, width: width), -0.5)
        XCTAssertEqual(Balance.dragged(from: 0.5, translation: 20, width: width), 0.7, accuracy: 1e-6)
        // 端で止まり、中央付近は吸着する。
        XCTAssertEqual(Balance.dragged(from: 0.9, translation: 100, width: width), 1)
        XCTAssertEqual(Balance.dragged(from: 0.05, translation: -1, width: width), 0)
        XCTAssertEqual(Balance.dragged(from: 0.3, translation: 50, width: 0), 0.3)
    }

    func testKnobPosition() {
        let width: CGFloat = 200
        XCTAssertEqual(Balance.x(of: -1, width: width), 0)
        XCTAssertEqual(Balance.x(of: 0, width: width), 100)
        XCTAssertEqual(Balance.x(of: 0.5, width: width), 150)
        XCTAssertEqual(Balance.x(of: 7, width: width), 200)
    }

    func testChannelGainsLowerOnlyOneSide() {
        var gains = Balance.channelGains(gain: 1, balance: 0)
        XCTAssertEqual(gains.left, 1); XCTAssertEqual(gains.right, 1)

        gains = Balance.channelGains(gain: 1, balance: -1)
        XCTAssertEqual(gains.left, 1); XCTAssertEqual(gains.right, 0)

        gains = Balance.channelGains(gain: 1, balance: 1)
        XCTAssertEqual(gains.left, 0); XCTAssertEqual(gains.right, 1)

        gains = Balance.channelGains(gain: 0.5, balance: 0.4)
        XCTAssertEqual(gains.left, 0.3, accuracy: 1e-6); XCTAssertEqual(gains.right, 0.5)

        gains = Balance.channelGains(gain: 0.5, balance: -0.4)
        XCTAssertEqual(gains.left, 0.5); XCTAssertEqual(gains.right, 0.3, accuracy: 1e-6)
    }

    func testChannelGainsNeverExceedGain() {
        for b in stride(from: Float(-1), through: 1, by: 0.1) {
            let gains = Balance.channelGains(gain: 0.8, balance: b)
            XCTAssertLessThanOrEqual(gains.left, 0.8)
            XCTAssertLessThanOrEqual(gains.right, 0.8)
            XCTAssertEqual(max(gains.left, gains.right), 0.8, accuracy: 1e-6)
        }
    }

    func testLabel() {
        XCTAssertEqual(Balance.label(0), "中央")
        XCTAssertEqual(Balance.label(0.004), "中央")
        XCTAssertEqual(Balance.label(-0.25), "L 25%")
        XCTAssertEqual(Balance.label(0.5), "R 50%")
        XCTAssertEqual(Balance.label(-1), "L 100%")
        XCTAssertEqual(Balance.label(4), "R 100%")
    }
}

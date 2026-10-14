import XCTest
@testable import AppMixer

final class MixerStateTests: XCTestCase {

    func testDefaultStateIsNotCustomized() {
        let state = MixerController.State()
        XCTAssertEqual(state.volume, 1)
        XCTAssertFalse(state.muted)
        XCTAssertEqual(state.balance, 0)
        XCTAssertNil(state.outputDeviceUID)
        XCTAssertFalse(state.isCustomized)
        XCTAssertFalse(state.hasBalance)
    }

    func testVolumeMuteRoutingAndBalanceEachCustomize() {
        XCTAssertTrue(MixerController.State(volume: 0.5).isCustomized)
        XCTAssertTrue(MixerController.State(muted: true).isCustomized)
        XCTAssertTrue(MixerController.State(outputDeviceUID: "dev").isCustomized)
        XCTAssertTrue(MixerController.State(balance: 0.3).isCustomized)
        XCTAssertTrue(MixerController.State(balance: -0.3).hasBalance)
        // 浮動小数の誤差程度は中央とみなす。
        XCTAssertFalse(MixerController.State(balance: 0.0005).isCustomized)
        XCTAssertFalse(MixerController.State(volume: 0.9995).isCustomized)
    }

    func testRequiresTap() {
        typealias S = MixerController.State
        XCTAssertFalse(MixerController.requiresTap(gain: 1, state: S()))
        XCTAssertFalse(MixerController.requiresTap(gain: 0.9995, state: S()))
        XCTAssertTrue(MixerController.requiresTap(gain: 0.5, state: S()))
        // ダッキングで下がったゲインも、見た目の設定が既定でもタップが要る。
        XCTAssertTrue(MixerController.requiresTap(gain: 0.2, state: S(volume: 1)))
        XCTAssertTrue(MixerController.requiresTap(gain: 1, state: S(outputDeviceUID: "dev")))
        XCTAssertTrue(MixerController.requiresTap(gain: 1, state: S(balance: -0.2)))
        XCTAssertFalse(MixerController.requiresTap(gain: 1, state: S(balance: 0.0005)))
    }

    func testUserGainIgnoresBalance() {
        XCTAssertEqual(MixerController.State(volume: 0.5, balance: 1).userGain, 0.5)
        XCTAssertEqual(MixerController.State(volume: 0.5, muted: true, balance: 1).userGain, 0)
    }
}

import XCTest
@testable import AppMixer

final class DuckingDetectorTests: XCTestCase {

    private func app(_ bundleID: String?, id: String? = nil,
                     output: Bool = false, input: Bool = false) -> AudioApp {
        AudioApp(id: id ?? bundleID ?? "pid:1", bundleID: bundleID, name: bundleID ?? "x",
                 processObjectIDs: [1], isRunningOutput: output, isRunningInput: input, iconAppPID: nil)
    }

    func testMeetingAndCommunicationApps() {
        XCTAssertTrue(DuckingDetector.isMeetingApp(app("us.zoom.xos")))
        XCTAssertTrue(DuckingDetector.isCommunicationApp(app("us.zoom.xos")))
        XCTAssertFalse(DuckingDetector.isMeetingApp(app("com.hnc.Discord")))
        XCTAssertTrue(DuckingDetector.isCommunicationApp(app("com.hnc.Discord")))
        XCTAssertFalse(DuckingDetector.isCommunicationApp(app("com.apple.Music")))
        XCTAssertFalse(DuckingDetector.isCommunicationApp(app(nil)))
    }

    func testSystemSoundsRowIsNeverDucked() {
        // FaceTime の相手の声はデーモン経由でこの行から出る。
        let system = app(nil, id: AudioApp.systemID)
        XCTAssertTrue(DuckingDetector.isCommunicationApp(system))
        XCTAssertFalse(DuckingDetector.isMeetingApp(system))
    }

    func testEvaluatePrefersMeetingAppThenMicrophone() {
        let zoom = app("us.zoom.xos", output: true)
        let mic = app("com.example.recorder", input: true)
        XCTAssertEqual(DuckingDetector.evaluate(apps: [mic, zoom], useMicrophone: false), "us.zoom.xos")
        XCTAssertEqual(DuckingDetector.evaluate(apps: [mic], useMicrophone: true), "マイク使用中")
        XCTAssertNil(DuckingDetector.evaluate(apps: [mic], useMicrophone: false))
        XCTAssertNil(DuckingDetector.evaluate(apps: [app("us.zoom.xos", output: false)], useMicrophone: true))
    }

    func testSystemSoundsMicrophoneTriggersDucking() {
        // 通話中（入出力が同時）のシステム音行はマイク使用として数える。
        let system = app(nil, id: AudioApp.systemID, output: true, input: true)
        XCTAssertEqual(DuckingDetector.evaluate(apps: [system], useMicrophone: true), "マイク使用中")
    }
}

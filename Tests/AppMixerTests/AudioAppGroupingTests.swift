import XCTest
import AppKit
import CoreAudio
@testable import AppMixer

/// 音声プロセスをアプリ単位にまとめる処理。HAL には触らない。
final class AudioAppGroupingTests: XCTestCase {

    private func regular(_ pid: pid_t, _ bundleID: String, _ name: String?) -> RunningProcess {
        RunningProcess(pid: pid, bundleID: bundleID, name: name, policy: .regular,
                       bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"))
    }

    /// pid -> 本体アプリ、という対応だけを持つ解決器。
    /// `transient` に入れた pid は、帰属できない XPC サービスとして扱う。
    private func identity(_ owners: [pid_t: RunningProcess],
                          transient: Set<pid_t> = []) -> ProcessIdentity {
        ProcessIdentity(
            regularApps: { [] },
            process: { pid in
                if transient.contains(pid) {
                    return RunningProcess(pid: pid, bundleID: "com.apple.WebKit.GPU", name: "x",
                                          policy: .accessory,
                                          bundleURL: URL(fileURLWithPath: "/System/x.xpc"))
                }
                return owners[pid]
            },
            parent: { _ in nil }
        )
    }

    private func record(_ objectID: AudioObjectID, pid: pid_t,
                        output: Bool = false, input: Bool = false) -> AudioProcessRecord {
        AudioProcessRecord(objectID: objectID, pid: pid, isRunningOutput: output, isRunningInput: input)
    }

    private func group(_ records: [AudioProcessRecord], owners: [pid_t: RunningProcess],
                       transient: Set<pid_t> = [],
                       own: String? = "com.iam74k4.AppMixer") -> [AudioApp] {
        AudioAppEnumerator.group(records, identity: identity(owners, transient: transient),
                                 ownBundleID: own)
    }

    func testHelpersOfOneAppBecomeOneRow() {
        let edge = regular(10, "com.microsoft.edgemac", "Microsoft Edge")
        let apps = group(
            [record(1, pid: 10), record(2, pid: 11, output: true), record(3, pid: 12, input: true)],
            owners: [10: edge, 11: edge, 12: edge]
        )
        XCTAssertEqual(apps.count, 1)
        let app = try! XCTUnwrap(apps.first)
        XCTAssertEqual(app.id, "com.microsoft.edgemac")
        XCTAssertEqual(app.bundleID, "com.microsoft.edgemac")
        XCTAssertEqual(app.name, "Microsoft Edge")
        XCTAssertEqual(Set(app.processObjectIDs), [1, 2, 3])
        XCTAssertTrue(app.isRunningOutput)
        XCTAssertTrue(app.isRunningInput)
        XCTAssertEqual(app.iconAppPID, 10)
        XCTAssertFalse(app.isSystem)
        XCTAssertEqual(app.storageKey, "com.microsoft.edgemac")
    }

    func testOwnProcessIsExcluded() {
        let me = regular(20, "com.iam74k4.AppMixer", "AppMixer")
        XCTAssertTrue(group([record(1, pid: 20, output: true)], owners: [20: me]).isEmpty)
    }

    func testInvalidPIDIsIgnored() {
        XCTAssertTrue(group([record(1, pid: 0), record(2, pid: -1)], owners: [:]).isEmpty)
    }

    func testNameFallsBackToBundleID() {
        let nameless = regular(30, "com.example.nameless", nil)
        let apps = group([record(1, pid: 30)], owners: [30: nameless])
        XCTAssertEqual(apps.first?.name, "com.example.nameless")
    }

    // MARK: - システム音

    func testOrphanProcessesBecomeSystemSoundsRow() {
        // loginwindow, systemsoundserverd, デーモン…: 本体アプリに行き着かない。
        let apps = group(
            [record(1, pid: 411, output: true), record(2, pid: 630), record(3, pid: 714)],
            owners: [:]
        )
        XCTAssertEqual(apps.count, 1)
        let system = try! XCTUnwrap(apps.first)
        XCTAssertTrue(system.isSystem)
        XCTAssertEqual(system.id, AudioApp.systemID)
        XCTAssertNil(system.bundleID)
        XCTAssertEqual(system.name, "システム音")
        XCTAssertEqual(Set(system.processObjectIDs), [1, 2, 3])
        XCTAssertTrue(system.isRunningOutput)
        XCTAssertNil(system.iconAppPID)
        // 設定は固定の id で保存する。
        XCTAssertEqual(system.storageKey, AudioApp.systemID)
    }

    func testSystemSoundsRowIsNotRunningOutputWhenNothingPlays() {
        let apps = group([record(1, pid: 411), record(2, pid: 630)], owners: [:])
        XCTAssertEqual(apps.first?.isRunningOutput, false)
    }

    func testSystemSoundsRowIgnoresMicrophoneOnlyListeners() {
        // "Hey Siri" の待ち受け（CoreSpeech）は常にマイクだけを掴んでいる。
        // 通話と見なすとダッキングが鳴りっぱなしになる。
        let apps = group([record(1, pid: 715, input: true)], owners: [:])
        XCTAssertEqual(apps.first?.isRunningInput, false)
    }

    func testSystemSoundsRowReportsMicrophoneDuringCalls() {
        // FaceTime の通話（avconferenced）は相手の声を出しつつマイクも使う。
        let apps = group(
            [record(1, pid: 715, input: true), record(2, pid: 796, output: true, input: true)],
            owners: [:]
        )
        XCTAssertEqual(apps.first?.isRunningInput, true)
        XCTAssertEqual(apps.first?.isRunningOutput, true)
    }

    func testTransientServicesStayOutOfSystemSoundsRow() {
        // Quick Look などの WebKit GPU プロセスは出入りが激しい。行に入れると
        // 顔ぶれが変わるたびにタップを張り直すことになる。
        let apps = group(
            [record(1, pid: 411), record(2, pid: 5000), record(3, pid: 5001, output: true)],
            owners: [:], transient: [5000, 5001]
        )
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.processObjectIDs, [1])
        XCTAssertEqual(apps.first?.isRunningOutput, false)
    }

    func testOnlyTransientServicesYieldNoSystemSoundsRow() {
        let apps = group([record(1, pid: 5000)], owners: [:], transient: [5000])
        XCTAssertTrue(apps.isEmpty)
    }

    func testNoSystemSoundsRowWithoutOrphans() {
        let safari = regular(40, "com.apple.Safari", "Safari")
        let apps = group([record(1, pid: 40)], owners: [40: safari])
        XCTAssertFalse(apps.contains { $0.isSystem })
    }

    func testSystemSoundsRowHasComputerIcon() {
        let apps = group([record(1, pid: 411)], owners: [:])
        XCTAssertNotNil(apps.first?.icon)
    }

    // MARK: - 並び順

    func testSortsRunningFirstThenNameThenSystemLast() {
        let zed = regular(50, "com.example.zed", "Zed")
        let alpha = regular(51, "com.example.alpha", "alpha")
        let beta = regular(52, "com.example.beta", "Beta")
        let apps = group(
            [
                record(1, pid: 50, output: true),
                record(2, pid: 51),
                record(3, pid: 52, output: true),
                record(4, pid: 411, output: true),   // システム音（再生中）
            ],
            owners: [50: zed, 51: alpha, 52: beta]
        )
        XCTAssertEqual(apps.map(\.id), [
            "com.example.beta", "com.example.zed", AudioApp.systemID, "com.example.alpha",
        ])
    }

    func testSortIsStableForSameNames() {
        let a = regular(60, "com.example.a", "Same")
        let b = regular(61, "com.example.b", "Same")
        let forward = group([record(1, pid: 60), record(2, pid: 61)], owners: [60: a, 61: b])
        let reversed = group([record(2, pid: 61), record(1, pid: 60)], owners: [60: a, 61: b])
        XCTAssertEqual(forward.map(\.id), ["com.example.a", "com.example.b"])
        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
    }

    // MARK: - Equatable

    func testEqualityIgnoresInputFlagAndIcon() {
        let lhs = AudioApp(id: "x", bundleID: "x", name: "X", processObjectIDs: [1, 2],
                           isRunningOutput: true, isRunningInput: false, iconAppPID: 1)
        let rhs = AudioApp(id: "x", bundleID: "x", name: "X", processObjectIDs: [1, 2],
                           isRunningOutput: true, isRunningInput: true, iconAppPID: 2)
        XCTAssertEqual(lhs, rhs)
        let stopped = AudioApp(id: "x", bundleID: "x", name: "X", processObjectIDs: [1, 2],
                               isRunningOutput: false, isRunningInput: false, iconAppPID: 1)
        XCTAssertNotEqual(lhs, stopped)
    }
}

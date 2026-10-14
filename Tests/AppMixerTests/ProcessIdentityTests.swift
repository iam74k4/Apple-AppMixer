import XCTest
import AppKit
@testable import AppMixer

/// 本体アプリの解決。実在しないプロセスの組み合わせを作って判断だけを試す。
final class ProcessIdentityTests: XCTestCase {

    // MARK: - 道具

    private func regular(_ pid: pid_t, _ bundleID: String, _ name: String,
                         path: String = "/Applications/App.app") -> RunningProcess {
        RunningProcess(pid: pid, bundleID: bundleID, name: name,
                       policy: .regular, bundleURL: URL(fileURLWithPath: path))
    }

    private func accessory(_ pid: pid_t, _ bundleID: String, _ name: String,
                           path: String) -> RunningProcess {
        RunningProcess(pid: pid, bundleID: bundleID, name: name,
                       policy: .accessory, bundleURL: URL(fileURLWithPath: path))
    }

    private func prohibited(_ pid: pid_t, _ bundleID: String?, _ name: String,
                            path: String) -> RunningProcess {
        RunningProcess(pid: pid, bundleID: bundleID, name: name,
                       policy: .prohibited, bundleURL: URL(fileURLWithPath: path))
    }

    private func identity(_ processes: [RunningProcess],
                          parents: [pid_t: pid_t] = [:]) -> ProcessIdentity {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let regular = processes.filter { $0.policy == .regular && $0.bundleID != nil }
        return ProcessIdentity(
            regularApps: { regular },
            process: { byPID[$0] },
            parent: { parents[$0] }
        )
    }

    // MARK: - 通常アプリとヘルパー

    func testRegularAppResolvesToItself() {
        let safari = regular(100, "com.apple.Safari", "Safari")
        let sut = identity([safari], parents: [100: 1])
        XCTAssertEqual(sut.owningProcess(of: 100), safari)
    }

    func testUnregisteredHelperWalksUpToRegularParent() {
        // Edge のヘルパーは NSRunningApplication に登録されない。親が本体。
        let edge = regular(200, "com.microsoft.edgemac", "Microsoft Edge")
        let sut = identity([edge], parents: [201: 200, 200: 1])
        XCTAssertEqual(sut.owningProcess(of: 201), edge)
    }

    func testAccessoryHelperInsideAppWalksUpToRegularParent() {
        // Discord Helper (Renderer) は .accessory で登録されるが、本体は Discord。
        let discord = regular(300, "com.hnc.Discord", "Discord", path: "/Applications/Discord.app")
        let helper = accessory(301, "com.hnc.Discord.helper.Renderer", "Discord Helper (Renderer)",
                               path: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app")
        let sut = identity([discord, helper], parents: [301: 300, 300: 1])
        XCTAssertEqual(sut.owningProcess(of: 301), discord)
    }

    func testMenuBarAppHelperResolvesToTopmostAccessory() {
        // Electron 製の常駐アプリは本体もヘルパーも .accessory。上の本体を採る。
        let main = accessory(400, "com.example.menubar", "MenuBar", path: "/Applications/MenuBar.app")
        let helper = accessory(401, "com.example.menubar.helper", "MenuBar Helper",
                               path: "/Applications/MenuBar.app/Contents/Frameworks/MenuBar Helper.app")
        let sut = identity([main, helper], parents: [401: 400, 400: 1])
        XCTAssertEqual(sut.owningProcess(of: 401), main)
        XCTAssertEqual(sut.owningProcess(of: 400), main)
    }

    func testRegularAncestorWinsOverAccessoryDescendant() {
        // ターミナルから直接起動した常駐アプリは、辿ると Terminal に着く。
        // 常駐アプリを見つけても止まらず、通常アプリまで辿り着いたらそちらを採る。
        let terminal = regular(500, "com.apple.Terminal", "Terminal")
        let menubar = accessory(501, "com.example.menubar", "MenuBar", path: "/Applications/MenuBar.app")
        let sut = identity([terminal, menubar], parents: [501: 500, 500: 1])
        XCTAssertEqual(sut.owningProcess(of: 501), terminal)
    }

    // MARK: - 裏方は本体なし

    func testLoginWindowIsNotAnApp() {
        let loginwindow = accessory(600, "com.apple.loginwindow", "loginwindow",
                                    path: "/System/Library/CoreServices/loginwindow.app")
        let sut = identity([loginwindow], parents: [600: 1])
        XCTAssertNil(sut.owningProcess(of: 600))
    }

    func testControlCenterAndSiriAreNotApps() {
        let controlCenter = accessory(601, "com.apple.controlcenter", "コントロールセンター",
                                      path: "/System/Library/CoreServices/ControlCenter.app")
        let siri = accessory(602, "com.apple.Siri", "Siri", path: "/System/Library/CoreServices/Siri.app")
        let sut = identity([controlCenter, siri], parents: [601: 1, 602: 1])
        XCTAssertNil(sut.owningProcess(of: 601))
        XCTAssertNil(sut.owningProcess(of: 602))
    }

    func testProhibitedProcessIsNotAnApp() {
        let daemon = prohibited(700, nil, "universalaccessd", path: "/usr/sbin/universalaccessd")
        let sut = identity([daemon], parents: [700: 1])
        XCTAssertNil(sut.owningProcess(of: 700))
    }

    func testUnregisteredDaemonIsNotAnApp() {
        // com.apple.accessibility.heard のような純粋なデーモン。登録が無く親は launchd。
        let sut = identity([], parents: [800: 1])
        XCTAssertNil(sut.owningProcess(of: 800))
    }

    func testAccessoryWithoutBundleIDIsSkipped() {
        let nameless = RunningProcess(pid: 900, bundleID: nil, name: "x", policy: .accessory,
                                      bundleURL: URL(fileURLWithPath: "/Applications/X.app"))
        let sut = identity([nameless], parents: [900: 1])
        XCTAssertNil(sut.owningProcess(of: 900))
    }

    // MARK: - WebKit の XPC サービス

    private static let gpuPath =
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"

    func testWebKitGPUProcessResolvesToHostApp() {
        let safari = regular(100, "com.apple.Safari", "Safari")
        let gpu = accessory(1000, "com.apple.WebKit.GPU", "Safari Graphics and Media", path: Self.gpuPath)
        let sut = identity([safari, gpu], parents: [1000: 1, 100: 1])
        XCTAssertEqual(sut.owningProcess(of: 1000), safari)
    }

    func testWebKitGPUProcessWithLocalizedHostName() {
        let mail = regular(101, "com.apple.mail", "メール")
        let gpu = accessory(1001, "com.apple.WebKit.GPU", "メール Graphics and Media", path: Self.gpuPath)
        let sut = identity([mail, gpu], parents: [1001: 1, 101: 1])
        XCTAssertEqual(sut.owningProcess(of: 1001), mail)
    }

    func testWebKitGPUProcessForBackgroundAgentHasNoOwner() {
        let safari = regular(100, "com.apple.Safari", "Safari")
        let gpu = accessory(1002, "com.apple.WebKit.GPU", "nsattributedstringagent Graphics and Media",
                            path: Self.gpuPath)
        let sut = identity([safari, gpu], parents: [1002: 1, 100: 1])
        XCTAssertNil(sut.owningProcess(of: 1002))
    }

    func testWebKitGPUHostMatchPrefersLongestName() {
        let app = regular(110, "com.example.app", "App")
        let appStore = regular(111, "com.apple.AppStore", "App Store")
        let gpu = accessory(1003, "com.apple.WebKit.GPU", "App Store Graphics and Media", path: Self.gpuPath)
        let sut = identity([app, appStore, gpu], parents: [1003: 1])
        XCTAssertEqual(sut.owningProcess(of: 1003), appStore)
    }

    func testWebKitGPUHostMatchRequiresWholeWord() {
        // "Safari" は "SafariX …" の前置詞ではない。
        let safari = regular(100, "com.apple.Safari", "Safari")
        let gpu = accessory(1004, "com.apple.WebKit.GPU", "SafariX Graphics and Media", path: Self.gpuPath)
        let sut = identity([safari, gpu], parents: [1004: 1])
        XCTAssertNil(sut.owningProcess(of: 1004))
    }

    func testNonWebKitXPCIsNotMatchedByName() {
        // 名前が一致しても WebKit の XPC でなければ帰属させない。
        let mail = regular(101, "com.apple.mail", "Mail")
        let xpc = prohibited(1006, "com.example.sync", "Mail Sync Helper",
                             path: "/Applications/Sync.app/Contents/XPCServices/Helper.xpc")
        let sut = identity([mail, xpc], parents: [1006: 1])
        XCTAssertNil(sut.owningProcess(of: 1006))
    }

    func testRegularAppsAreOnlyConsultedForWebKitXPC() {
        // 起動アプリの走査は XPC に出会うまで行わない。
        var consulted = 0
        let sut = ProcessIdentity(
            regularApps: { consulted += 1; return [] },
            process: { _ in nil },
            parent: { _ in nil }
        )
        XCTAssertNil(sut.owningProcess(of: 42))
        XCTAssertEqual(consulted, 0)
    }

    func testTransientService() {
        let xpc = accessory(1007, "com.apple.WebKit.GPU", "x Graphics and Media", path: Self.gpuPath)
        let siriNC = prohibited(1008, "com.apple.SiriNCService", "SiriNCService",
                                path: "/System/Library/CoreServices/Siri.app/Contents/XPCServices/SiriNCService.xpc")
        let loginwindow = accessory(600, "com.apple.loginwindow", "loginwindow",
                                    path: "/System/Library/CoreServices/loginwindow.app")
        let sut = identity([xpc, siriNC, loginwindow])
        XCTAssertTrue(sut.isTransientService(1007))
        XCTAssertTrue(sut.isTransientService(1008))
        XCTAssertFalse(sut.isTransientService(600))
        XCTAssertFalse(sut.isTransientService(9999))   // 登録の無いデーモン
    }

    func testNonXPCSystemAccessoryIsNotMatchedByName() {
        // 名前が一致しても .xpc でなければ帰属させない（偶然の一致を避ける）。
        let safari = regular(100, "com.apple.Safari", "Safari")
        let agent = accessory(1005, "com.apple.something", "Safari Agent",
                              path: "/System/Library/CoreServices/SafariAgent.app")
        let sut = identity([safari, agent], parents: [1005: 1])
        XCTAssertNil(sut.owningProcess(of: 1005))
    }

    // MARK: - 安全装置

    func testParentCycleTerminates() {
        let sut = identity([], parents: [1100: 1101, 1101: 1100])
        XCTAssertNil(sut.owningProcess(of: 1100))
    }

    func testSelfParentTerminates() {
        let sut = identity([], parents: [1200: 1200])
        XCTAssertNil(sut.owningProcess(of: 1200))
    }

    // MARK: - isUserFacing

    func testIsUserFacing() {
        XCTAssertTrue(ProcessIdentity.isUserFacing(regular(1, "a", "A")))
        XCTAssertTrue(ProcessIdentity.isUserFacing(
            accessory(2, "b", "B", path: "/Applications/B.app")))
        XCTAssertTrue(ProcessIdentity.isUserFacing(
            accessory(3, "c", "C", path: "/Users/me/Applications/C.app")))
        XCTAssertFalse(ProcessIdentity.isUserFacing(
            accessory(4, "d", "D", path: "/System/Library/CoreServices/D.app")))
        XCTAssertFalse(ProcessIdentity.isUserFacing(
            accessory(5, "e", "E", path: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/E.xpc")))
        XCTAssertFalse(ProcessIdentity.isUserFacing(
            RunningProcess(pid: 6, bundleID: "f", name: "F", policy: .accessory, bundleURL: nil)))
        XCTAssertFalse(ProcessIdentity.isUserFacing(
            prohibited(7, "g", "G", path: "/Applications/G.app")))
    }
}

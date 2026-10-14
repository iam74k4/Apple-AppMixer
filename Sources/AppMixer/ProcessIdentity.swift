import AppKit
import Darwin

// 音を出しているプロセスの「本体アプリ」を解決する。
//
// Chromium/Electron 系（Edge, Chrome, Discord, Slack, VS Code…）は
// 音声をヘルパーの子プロセスから出すため、CoreAudio が返す pid は
// "com.microsoft.edge.helper" のようなヘルパーになる。
// 親 pid を辿って、アイコンと分かりやすい名前を持つ通常アプリ
// (activationPolicy == .regular) を見つける。
//
// CoreAudio のプロセス一覧には、アプリとは呼べない裏方も並ぶ:
// デーモン (com.apple.accessibility.heard, CoreSpeech, audiomxd …)、
// loginwindow・コントロールセンター・通知センター・Siri のような
// macOS 自身の常駐部品、各種 XPC サービス。音量を変える相手ではなく、
// アイコンも名前もまともに出ないので、本体アプリが無いものとして扱う。
// それらの音は AudioAppEnumerator が「システム音」の 1 行にまとめる。

/// 一覧の解決に必要なぶんだけのプロセス情報。
///
/// NSRunningApplication を直接持ち回らず、この形に写してから判断する。
/// 実在しないプロセスの組み合わせ（テスト）でも同じ判断を通せるようにするため。
struct RunningProcess: Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String?
    let policy: NSApplication.ActivationPolicy
    let bundleURL: URL?

    init(pid: pid_t, bundleID: String?, name: String?,
         policy: NSApplication.ActivationPolicy, bundleURL: URL?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.policy = policy
        self.bundleURL = bundleURL
    }

    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            policy: app.activationPolicy,
            bundleURL: app.bundleURL
        )
    }
}

struct ProcessIdentity {

    /// 起動中の通常アプリ（bundleID 付き）。XPC サービスの帰属先の候補。
    /// 要るのは WebKit の XPC に出会ったときだけなので、呼ばれるまで作らない。
    let regularApps: () -> [RunningProcess]
    /// pid からプロセス情報を引く。登録の無いプロセス（純粋なデーモン等）は nil。
    let process: (pid_t) -> RunningProcess?
    /// pid の親 pid。取れなければ nil。
    let parent: (pid_t) -> pid_t?

    init(regularApps: @escaping () -> [RunningProcess],
         process: @escaping (pid_t) -> RunningProcess?,
         parent: @escaping (pid_t) -> pid_t?) {
        self.regularApps = regularApps
        self.process = process
        self.parent = parent
    }

    /// 実際の OS に問い合わせる構成。一覧を一度に解決する間は同じものを使い回す。
    static func live() -> ProcessIdentity {
        // 一覧は毎秒作り直されるため、起動アプリの走査は必要になった列挙でだけ、
        // それも 1 回に留める。
        var cached: [RunningProcess]?
        return ProcessIdentity(
            regularApps: {
                if let cached { return cached }
                let regular = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                    .map(RunningProcess.init)
                cached = regular
                return regular
            },
            process: { pid in NSRunningApplication(processIdentifier: pid).map(RunningProcess.init) },
            parent: parentPID(of:)
        )
    }

    /// 本体アプリに行き着かないプロセスのうち、「システム音」にも入れないもの。
    ///
    /// XPC サービスは使っているアプリに付いて生まれては消える（Quick Look や
    /// メールの下書きのたびに WebKit の GPU プロセスが起動する）。これを
    /// システム音の行に入れると、行の顔ぶれが頻繁に変わって、行を調整して
    /// いる間はそのたびにタップを張り直し、再生中の全アプリが音飛びする。
    /// ユーザーに聞こえる音を出すのはアプリ本体か常駐のデーモンなので、
    /// 帰属できなかった XPC サービスは行に入れない。
    func isTransientService(_ pid: pid_t) -> Bool {
        process(pid)?.bundleURL?.pathExtension == "xpc"
    }

    /// pid が属する本体アプリ。ユーザーから見えるアプリに行き着かなければ nil。
    func owningProcess(of pid: pid_t) -> RunningProcess? {
        var current = pid
        var depth = 0
        // 通常アプリが見つかればそれ。見つからなければ、辿った中でいちばん上の
        // メニューバー常駐アプリ (.accessory) を本体とみなす。Electron 製の
        // 常駐アプリは本体もヘルパーも .accessory なので、手前のヘルパー
        // ではなく上の本体を採る。
        var topmostAccessory: RunningProcess?

        while current > 1 && depth < 16 {
            if let app = process(current), app.bundleID != nil {
                switch app.policy {
                case .regular:
                    return app
                case .accessory where Self.isUserFacing(app):
                    topmostAccessory = app
                default:
                    break
                }
            }
            guard let next = parent(current), next != current else { break }
            current = next
            depth += 1
        }
        if let topmostAccessory { return topmostAccessory }

        return hostApplication(ofXPCService: pid)
    }

    /// 一覧に出す値打ちのある、ユーザーから見えるアプリか。
    ///
    /// 通常アプリ (.regular) は常に見える。メニューバー常駐アプリ (.accessory)
    /// には loginwindow・コントロールセンター・PowerChime・WebKit の XPC
    /// サービスといった macOS の部品も混ざるため、システム領域にあるものは
    /// 外す。それらは Dock にもアプリ切り替えにも出ず、固有のアイコンも
    /// 持たない。デーモンや XPC サービス (.prohibited) は見えない。
    static func isUserFacing(_ app: RunningProcess) -> Bool {
        switch app.policy {
        case .regular:
            return true
        case .accessory:
            guard let path = app.bundleURL?.path else { return false }
            // Cryptex に載った OS 部品は /System/Volumes/Preboot/Cryptexes/
            // 配下に見えるが、これも /System/ で始まる。
            return !path.hasPrefix("/System/")
        case .prohibited:
            return false
        @unknown default:
            return false
        }
    }

    /// XPC サービスを、それを使っているアプリに帰属させる。
    ///
    /// Safari やメールなど WebKit を使うアプリは、音声を WebKit の GPU
    /// プロセス (com.apple.WebKit.GPU) から出す。これは launchd が起動する
    /// XPC サービスで親を辿っても本体に着かず、しかも全アプリで同じ
    /// bundleID を持つため、放っておくと Safari もメールも「〜 Graphics and
    /// Media」という名前だけで 1 行にまとめられ、アイコンも出ない。
    ///
    /// WebKit はこのプロセスに「<使っているアプリ名> Graphics and Media」
    /// という名前を付けるので、起動中の通常アプリの名前で前方一致させて
    /// 本体を決める。見つからなければ、サムネイル生成など裏方の利用なので nil。
    private func hostApplication(ofXPCService pid: pid_t) -> RunningProcess? {
        guard let service = process(pid),
              service.bundleURL?.pathExtension == "xpc",
              // 名前の前方一致はこの WebKit の命名に頼っている。他の XPC に
              // 広げると、偶然アプリ名で始まる無関係なサービスまで帰属させる。
              service.bundleID?.hasPrefix("com.apple.WebKit.") == true,
              let serviceName = service.name
        else { return nil }

        return regularApps()
            .filter { app in
                guard let name = app.name, !name.isEmpty else { return false }
                return serviceName.hasPrefix(name + " ")
            }
            // 「App」と「App Store」のように一方が他方の前置詞なら長い方を採る。
            .max { ($0.name?.count ?? 0) < ($1.name?.count ?? 0) }
    }

    /// 指定 pid の親 pid を sysctl(KERN_PROC) で取得する。
    static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}

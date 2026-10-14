import AppKit
import CoreAudio

// アプリ単位にまとめた音声プロセス群。
// 1つのアプリ（例: Microsoft Edge）が複数の音声ヘルパーを持つため、
// それらを本体アプリ単位でグルーピングし、1行=1アプリで扱う。

struct AudioApp: Identifiable, Equatable {
    /// アプリに属さない音（通知音・効果音・デーモン）をまとめた行の id。
    static let systemID = "appmixer.system"

    let id: String                       // bundleID（無ければ "pid:<owner>"）。永続化キーも兼ねる
    let bundleID: String?
    let name: String
    let processObjectIDs: [AudioObjectID] // このアプリの全音声プロセスオブジェクト（タップ対象）
    let isRunningOutput: Bool             // いずれかのプロセスが現在出力中か
    let isRunningInput: Bool              // いずれかのプロセスが現在マイクを使用中か

    /// アイコン取得用の本体アプリ pid。再起動すると変わるため、
    /// 取得済みアイコンが同じ世代のものかの見分けにも使う。
    let iconAppPID: pid_t?

    init(id: String, bundleID: String?, name: String,
         processObjectIDs: [AudioObjectID],
         isRunningOutput: Bool, isRunningInput: Bool, iconAppPID: pid_t?) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
        self.iconAppPID = iconAppPID
    }

    /// 「システム音」の行か。
    var isSystem: Bool { id == Self.systemID }

    /// 設定の保存に使うキー。bundleID の無い行（pid 由来の仮の id）は
    /// 再起動すると別物になるので保存しない。システム音の行は常に同じ id
    /// なので、その id で保存する。
    var storageKey: String? {
        if let bundleID { return bundleID }
        return isSystem ? id : nil
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id &&
        lhs.processObjectIDs == rhs.processObjectIDs &&
        lhs.isRunningOutput == rhs.isRunningOutput
    }

    var icon: NSImage? {
        if isSystem {
            return NSImage(named: NSImage.computerName)
        }
        if let pid = iconAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            return app.icon
        }
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

/// HAL のプロセスオブジェクト 1 つぶんの、一覧の組み立てに要る情報。
struct AudioProcessRecord: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

enum AudioAppEnumerator {

    private static let ownBundleID = Bundle.main.bundleIdentifier

    /// 全ての音声プロセスを本体アプリ単位にまとめて返す。
    static func enumerate() -> [AudioApp] {
        group(records(), identity: .live(), ownBundleID: ownBundleID)
    }

    /// HAL のプロセス一覧を読む。
    static func records() -> [AudioProcessRecord] {
        let objectIDs = CoreAudioObject.readArray(.system, selector: kAudioHardwarePropertyProcessObjectList)
        return objectIDs.map { objectID in
            let pid: pid_t = CoreAudioObject.read(objectID, selector: kAudioProcessPropertyPID, defaultValue: pid_t(-1))
            return AudioProcessRecord(
                objectID: objectID,
                pid: pid,
                isRunningOutput: isRunningOutput(objectID),
                isRunningInput: isRunningInput(objectID)
            )
        }
    }

    /// プロセスを本体アプリ単位にまとめる。
    ///
    /// ユーザーから見えるアプリに行き着かないもの（デーモン、loginwindow
    /// のような macOS の部品、裏方の XPC サービス）は、個別の行にしない。
    /// bundleID だけで出すと "com.apple.accessibility.heard" のような名前が
    /// アイコン無しで並び、音量を変えて効果音が鳴るたびに loginwindow が
    /// 顔を出す。それらはまとめて「システム音」の 1 行にする。通知音や
    /// 警告音はここから鳴るので、音量を変えたい相手ではある。
    static func group(_ records: [AudioProcessRecord],
                      identity: ProcessIdentity,
                      ownBundleID: String?) -> [AudioApp] {
        // key -> 集約中データ
        final class Builder {
            var bundleID: String?
            var name: String
            var iconAppPID: pid_t?
            var objectIDs: [AudioObjectID] = []
            var runningOutput = false
            var runningInput = false
            init(bundleID: String?, name: String, iconAppPID: pid_t?) {
                self.bundleID = bundleID
                self.name = name
                self.iconAppPID = iconAppPID
            }
        }

        var builders: [String: Builder] = [:]

        for record in records {
            guard record.pid > 0 else { continue }

            let key: String
            let builder: Builder
            if let owner = identity.owningProcess(of: record.pid) {
                let bundleID = owner.bundleID

                // 自分自身は除外
                if let bundleID, bundleID == ownBundleID { continue }

                let name: String
                if let localized = owner.name, !localized.isEmpty {
                    name = localized
                } else if let bundleID {
                    name = bundleID
                } else {
                    continue
                }

                key = bundleID ?? "pid:\(owner.pid)"
                builder = builders[key] ?? Builder(bundleID: bundleID, name: name, iconAppPID: owner.pid)
            } else {
                // 帰属できなかった XPC サービスは、聞こえる音を出さないうえに
                // 顔ぶれが頻繁に変わるので入れない（isTransientService を参照）。
                if identity.isTransientService(record.pid) { continue }
                key = AudioApp.systemID
                builder = builders[key] ?? Builder(
                    bundleID: nil, name: localized("システム音"), iconAppPID: nil
                )
            }

            builder.objectIDs.append(record.objectID)
            if record.isRunningOutput { builder.runningOutput = true }
            if record.isRunningInput {
                // システム音では、マイクだけ掴んでいるプロセスを通話と見なさない。
                // "Hey Siri" の待ち受け（CoreSpeech）が常にマイクを開いていて、
                // 拾うとダッキングが鳴りっぱなしになる。FaceTime や iPhone の
                // 通話（avconferenced）は相手の声も出しているので、入出力が
                // 同時に動いているものだけを通話の合図にする。
                if key != AudioApp.systemID || record.isRunningOutput {
                    builder.runningInput = true
                }
            }
            builders[key] = builder
        }

        let apps = builders.map { key, b in
            AudioApp(
                id: key,
                bundleID: b.bundleID,
                name: b.name,
                processObjectIDs: b.objectIDs,
                isRunningOutput: b.runningOutput,
                isRunningInput: b.runningInput,
                iconAppPID: b.iconAppPID
            )
        }

        // 同名・同状態のアプリで順序が揺れると一覧を作り直し続けてしまうため、
        // id で必ず決着をつける。システム音はアプリの後ろに置く。
        return apps.sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            if $0.isSystem != $1.isSystem { return $1.isSystem }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id < $1.id
        }
    }

    /// このプロセスが今まさに音を出しているか。
    /// IsRunningOutput を持たないプロセスオブジェクトもあるため、
    /// 無い場合は IsRunning にフォールバックする。これを怠ると、
    /// 実際は再生中のアプリが一覧から漏れる。
    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        if CoreAudioObject.hasProperty(objectID, selector: kAudioProcessPropertyIsRunningOutput) {
            // このプロパティがあるなら、その値がそのまま答え。
            // false のときに IsRunning へ落とすと、入力だけのプロセス
            // （通話中のマイクなど）まで「再生中」と誤判定してしまう。
            let value: UInt32 = CoreAudioObject.read(
                objectID, selector: kAudioProcessPropertyIsRunningOutput, defaultValue: 0
            )
            return value != 0
        }
        if CoreAudioObject.hasProperty(objectID, selector: kAudioProcessPropertyIsRunning) {
            let value: UInt32 = CoreAudioObject.read(
                objectID, selector: kAudioProcessPropertyIsRunning, defaultValue: 0
            )
            return value != 0
        }
        return false
    }

    /// このプロセスが今まさにマイクを使っているか。
    /// 出力と違って IsRunning へのフォールバックはしない。落とすと、
    /// 再生しているだけのアプリまで「マイク使用中」と誤判定してしまう。
    private static func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        guard CoreAudioObject.hasProperty(
            objectID, selector: kAudioProcessPropertyIsRunningInput
        ) else { return false }
        let value: UInt32 = CoreAudioObject.read(
            objectID, selector: kAudioProcessPropertyIsRunningInput, defaultValue: 0
        )
        return value != 0
    }
}

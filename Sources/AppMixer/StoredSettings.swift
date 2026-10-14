import Foundation

// アプリ 1 つぶんの保存形式。
//
// 音量とミュートと左右バランスは「アプリ × 出力デバイス」で覚える。
// ヘッドフォンとスピーカーでは適正音量が違うため、1 つしか覚えないと
// 挿し替えるたびに調整し直しになる。
// 出力先の振り分け（ルーティング）はデバイスに依存しないのでアプリ単位。

/// あるデバイスでの音量設定。
struct DeviceVolume: Codable, Equatable {
    var volume: Float
    var muted: Bool
    /// 左右バランス（-1...1）。1.0.x の保存内容には無いので、無ければ中央。
    var balance: Float = 0

    init(volume: Float, muted: Bool, balance: Float = 0) {
        self.volume = volume
        self.muted = muted
        self.balance = balance
    }

    private enum CodingKeys: String, CodingKey {
        case volume, muted, balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decode(Float.self, forKey: .volume)
        muted = try container.decode(Bool.self, forKey: .muted)
        balance = try container.decodeIfPresent(Float.self, forKey: .balance) ?? 0
    }
}

/// アプリ 1 つぶんの保存内容。
///
/// 形が変わっても古い保存内容を捨てずに読めるよう、版番号を持たせ、
/// 各項目は「無ければ既定値」で読む。新しい版が増えた項目を、
/// 古いアプリが読み落として黙って消す事故を避けるための備え。
struct StoredSettings: Codable, Equatable {
    /// この形式の版。読み書きの互換判断に使う。
    /// 2: 左右バランスを追加（1.0.x は版 1 を書く。2 は読めるが書き戻さない）。
    var version: Int = StoredSettings.currentVersion
    /// 振り分け先（nil なら既定出力に追従）。
    var outputDeviceUID: String?
    /// 出力デバイス UID -> 音量設定。
    var perDevice: [String: DeviceVolume] = [:]
    /// 最後に使った音量。まだ記憶の無いデバイスへ移ったときの引き継ぎ元。
    /// これが無いと、鳴っていない間にデバイスが変わったアプリだけ
    /// 100% で鳴り出してしまう（鳴っていた場合は引き継がれるのに）。
    var lastKnown: DeviceVolume?

    static let currentVersion = 2

    init(outputDeviceUID: String? = nil) {
        self.outputDeviceUID = outputDeviceUID
    }

    private enum CodingKeys: String, CodingKey {
        case version, outputDeviceUID, perDevice, lastKnown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 版が無いものは v1 より前の何かとして扱う。いまのところ
        // 出荷済みの旧形式は無いので、既定値のまま読み進めればよい。
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        perDevice = try container.decodeIfPresent(
            [String: DeviceVolume].self, forKey: .perDevice) ?? [:]
        lastKnown = try container.decodeIfPresent(DeviceVolume.self, forKey: .lastKnown)
    }

    /// このアプリより新しい版で書かれているか。読める範囲は使うが、
    /// 書き戻すと知らない項目が落ちるため上書きしてはいけない。
    var isNewerThanSupported: Bool { version > Self.currentVersion }
}

import Foundation
import CoreAudio
import Accelerate
import os

/// IOProc（オーディオスレッド）と UI スレッドで共有する状態。
///
/// IOProc から `weak self` を辿ると弱参照ロードでロック/retain が走り
/// リアルタイム安全ではないため、値だけを持つ箱を強参照でキャプチャする。
///
/// 二つのスレッドが同期なしで触るため、形式的にはデータ競合がある。承知のうえで
/// そうしている。中身は整列した 4 バイトの Float だけで、項目ごとに書き手が
/// 一つに決まっている（targetGain と rampStep は UI 側、currentGain と level は
/// IOProc 側）。対応アーキテクチャでは整列した 4 バイトの読み書きが裂けないため、
/// 半端な値が読まれることはない。読み手が 1 周期古い値を見るだけで、
/// ゲインは元々なめらかに追従させるので実害が無い。
///
/// ロックは使わない。IOProc でロックを取ると、待たされた瞬間にバッファを落として
/// 音が途切れる。形式的な競合を消すために実際の音を犠牲にしては本末転倒になる。
/// `Synchronization` の `Atomic` は macOS 15 以降で、このアプリの配備対象
/// （macOS 14.4）では使えない。
final class TapState: @unchecked Sendable {
    /// UI が書き、IOProc が目標として読む左右のゲイン（0.0...1.0）。
    /// 全体の音量とバランスを掛け合わせた値。ステレオでなければ左右は同じ。
    var targetLeft: Float = 1.0
    var targetRight: Float = 1.0
    /// IOProc が保持する現在のゲイン。目標へ向かって滑らかに動く。
    var currentLeft: Float = 1.0
    var currentRight: Float = 1.0
    /// 1 フレーム（チャンネルごとに 1 サンプル）あたりのゲイン変化量。
    /// 急変によるプチノイズを防ぐ。
    var rampStep: Float = 1.0 / 2048.0
    /// IOProc が書き、UI が読む（直近ピーク 0...1）。
    var level: Float = 0
    /// タップの形式。activate が決め、以後は読むだけ。
    /// バランスはステレオのときだけ意味を持つ。
    var channelCount: Int = 2
    var isInterleaved: Bool = true
}

// 1 アプリ（複数の音声プロセスを含む）に対する Process Tap。
//
// 構成（Pattern A）:
//   - CATapDescription(stereoMixdownOfProcesses: [全プロセス]) + .mutedWhenTapped
//     → 対象アプリの音は通常経路から消える（二重再生防止）
//   - プライベート集約デバイス = 出力デバイス + このタップ
//   - 単一 IOProc が「タップ入力 × ゲイン」を出力へ書き込み、同時にピークを計測
//
// 出力デバイスは既定出力（outputDeviceUID == nil）か、指定したデバイス。
// 指定するとそのアプリだけ別のデバイスから鳴らせる（アプリ別ルーティング）。

final class ProcessTap {

    enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case noOutputDevice
        case unsupportedFormat(AudioStreamBasicDescription)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):       return "AudioHardwareCreateProcessTap failed (\(s))"
            case .noOutputDevice:                 return "No output device / UID"
            case .unsupportedFormat(let f):
                return "Unsupported format (flags: \(f.mFormatFlags), ch: \(f.mChannelsPerFrame))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s):             return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    /// ゲイン変化にかける時間。短すぎるとプチッと鳴り、長すぎると反応が鈍く感じる。
    private static let rampSeconds = 0.08

    let processObjectIDs: [AudioObjectID]

    /// 出力先デバイスの UID。nil なら既定出力デバイスに追従する。
    let outputDeviceUID: String?

    /// 既定出力デバイスの変更に追従すべきタップか。
    var followsDefaultOutput: Bool { outputDeviceUID == nil }

    /// IOProc と共有する状態（ゲイン / メーター）。
    let state = TapState()

    /// 目標ゲイン（0.0...1.0）。実際の適用は数十 ms かけて滑らかに追従する。
    var gain: Float = 1.0 {
        didSet { pushTargets() }
    }

    /// 左右バランス（-1...1）。片側を絞るだけで、反対側は持ち上げない。
    var balance: Float = 0 {
        didSet { pushTargets() }
    }

    /// 音量とバランスから左右の目標ゲインを決めて IOProc へ渡す。
    private func pushTargets() {
        let gains = state.channelCount == 2
            ? Balance.channelGains(gain: gain, balance: balance)
            : (left: gain, right: gain)
        state.targetLeft = gains.left
        state.targetRight = gains.right
    }

    /// 現在のゲインを目標に揃える（フェードさせずにその値から始める）。
    /// 新しく張るタップで、鳴り始めに音量が滑り込むのを防ぐ。
    func snapToTarget() {
        state.currentLeft = state.targetLeft
        state.currentRight = state.targetRight
    }

    /// 直近のピーク（0...1）。メーター表示用。
    var level: Float { state.level }

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], outputDeviceUID: String? = nil) {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
    }

    deinit { invalidate() }

    // MARK: - Lifecycle

    func activate() throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var newTapID: AudioObjectID = .unknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID.isValid else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // レンダリングは 32bit float 前提のため、フォーマットを検証してから進む。
        let format: AudioStreamBasicDescription = CoreAudioObject.read(
            tapID, selector: kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription()
        )
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            invalidate()
            throw TapError.unsupportedFormat(format)
        }

        // フェード時間から 1 フレームあたりの変化量を決める（およそ 80ms）。
        // render はチャンネルごとに 1 サンプルずつゲインを進めるので、
        // インターリーブでもそうでなくても 1 フレーム = 1 歩になる。
        let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        state.rampStep = Float(1.0 / (sampleRate * Self.rampSeconds))
        state.channelCount = max(1, Int(format.mChannelsPerFrame))
        state.isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // 形式が決まったので、バランスを左右のゲインへ反映し直す。
        pushTargets()
        snapToTarget()

        // 出力先。指定が無ければ既定出力を使う。
        let outputUID: String
        if let outputDeviceUID {
            outputUID = outputDeviceUID
        } else {
            let deviceID = CoreAudioObject.defaultOutputDeviceID()
            guard deviceID.isValid, let uid = CoreAudioObject.deviceUID(deviceID) else {
                invalidate()
                throw TapError.noOutputDevice
            }
            outputUID = uid
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer-\(aggregateUID.prefix(8))",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [ kAudioSubDeviceUIDKey: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = .unknown
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        // 生成されたデバイスを取りこぼさないよう、guard の前に保持する。
        aggregateID = newAggregateID
        guard aggStatus == noErr, newAggregateID.isValid else {
            invalidate()
            throw TapError.aggregateCreationFailed(aggStatus)
        }

        // 出力側のフォーマットがタップと一致しない場合、単純なバッファコピーでは
        // 早回し再生やノイズになる。取り違えた音を出すより起動を諦める。
        //
        // フォーマットはデバイスではなく「ストリーム」のプロパティなので、
        // 集約デバイスに直接聞いても取れない。読めなかったときは通すのではなく
        // 諦める（fail closed）。通してしまうと、この検査そのものが素通りする。
        guard let outFormat = CoreAudioObject.outputStreamFormat(aggregateID) else {
            invalidate()
            throw TapError.unsupportedFormat(AudioStreamBasicDescription())
        }
        let interleavedFlag = kAudioFormatFlagIsNonInterleaved
        guard outFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              outFormat.mBitsPerChannel == 32,
              outFormat.mChannelsPerFrame == format.mChannelsPerFrame,
              (outFormat.mFormatFlags & interleavedFlag)
                == (format.mFormatFlags & interleavedFlag) else {
            invalidate()
            throw TapError.unsupportedFormat(outFormat)
        }

        // 箱を強参照でキャプチャし、IOProc 内で self に触れないようにする。
        let state = self.state
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, state: state)
        }
        // キューを渡すと通常優先度のキュー上でレンダリングされ、負荷時に
        // バッファを落とす。nil を渡してデバイスの IO スレッドで動かす。
        // render は確保もロックも行わないためリアルタイムスレッドで安全。
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock)
        guard procStatus == noErr, let procID else {
            invalidate()
            throw TapError.ioProcCreationFailed(procStatus)
        }
        deviceProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.startFailed(startStatus)
        }
    }

    /// タップと集約デバイスを完全に破棄できたか。
    /// false のままだと対象アプリは .mutedWhenTapped のまま無音になるため、
    /// 呼び出し側は破棄が終わるまで解放せずに再試行する。
    var isFullyTornDown: Bool { !tapID.isValid && !aggregateID.isValid }

    /// タップを破棄して対象アプリの音声を通常経路へ戻す。
    /// デバイス切替中などで HAL が破棄に失敗することがあるため、
    /// 失敗した ID は保持し、次回の呼び出しで再試行できるようにする。
    func invalidate() {
        if let procID = deviceProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            deviceProcID = nil
        }

        if aggregateID.isValid {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr {
                aggregateID = .unknown
            } else {
                AppLog.audio.error("DestroyAggregateDevice failed (\(status, privacy: .public)); will retry")
            }
        }
        if tapID.isValid {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                tapID = .unknown
            } else {
                AppLog.audio.error("DestroyProcessTap failed (\(status, privacy: .public)); will retry")
            }
        }
        state.level = 0
    }

    // MARK: - Realtime render (audio thread)

    /// タップ入力にゲインを掛けて出力へ書き、ピークを計る。
    ///
    /// 左右で別のゲインを持つ。ステレオのインターリーブ形式では偶数スロットが
    /// 左、奇数スロットが右。非インターリーブ形式ではバッファ 0 が左、1 が右。
    /// それ以外（モノラル、3ch 以上）はバランスを持たず、左のゲインを全体に掛ける
    /// （pushTargets が左右を同じ値にしている）。
    ///
    /// 確保もロックもしない。IO スレッドで呼ばれるため。
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: TapState
    ) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        // 先に出力を無音化しておく。書き込まなかった領域に前サイクルの
        // 音が残って繰り返しノイズになるのを防ぐ。
        for i in 0..<outBuffers.count {
            if let outData = outBuffers[i].mData {
                memset(outData, 0, Int(outBuffers[i].mDataByteSize))
            }
        }

        let startLeft = state.currentLeft
        let startRight = state.currentRight
        let targetLeft = state.targetLeft
        let targetRight = state.targetRight
        let step = state.rampStep
        var endLeft = startLeft
        var endRight = startRight
        var peak: Float = 0
        let pairCount = min(inBuffers.count, outBuffers.count)
        let stereo = state.channelCount == 2

        for i in 0..<pairCount {
            let inBuffer = inBuffers[i]
            let outBuffer = outBuffers[i]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let byteCount = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
            let count = Int(byteCount) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let inPtr = inData.assumingMemoryBound(to: Float.self)
            let outPtr = outData.assumingMemoryBound(to: Float.self)

            var localPeak: Float = 0
            vDSP_maxmgv(inPtr, 1, &localPeak, vDSP_Length(count))
            peak = max(peak, localPeak)

            if stereo && state.isInterleaved {
                // L R L R … と並ぶ。1 つおきに辿って左右を別々に掛ける。
                let frames = count / 2
                endLeft = applyGain(inPtr, outPtr, stride: 2, count: frames,
                                    from: startLeft, to: targetLeft, step: step)
                endRight = applyGain(inPtr + 1, outPtr + 1, stride: 2, count: frames,
                                     from: startRight, to: targetRight, step: step)
            } else if stereo {
                // チャンネルごとに別のバッファ。0 が左、1 が右。
                // それ以上のバッファは形式と矛盾しているので無音のままにする
                // （左右のフェードの進みを壊さない）。
                if i == 0 {
                    endLeft = applyGain(inPtr, outPtr, stride: 1, count: count,
                                        from: startLeft, to: targetLeft, step: step)
                } else if i == 1 {
                    endRight = applyGain(inPtr, outPtr, stride: 1, count: count,
                                         from: startRight, to: targetRight, step: step)
                }
            } else {
                // バランスの無い形式。インターリーブなら 1 フレームにチャンネル数
                // ぶんのスロットがあるので、歩幅を割ってフェード時間を保つ。
                let slotStep = state.isInterleaved ? step / Float(max(1, state.channelCount)) : step
                endLeft = applyGain(inPtr, outPtr, stride: 1, count: count,
                                    from: startLeft, to: targetLeft, step: slotStep)
                endRight = endLeft
            }
        }

        state.currentLeft = endLeft
        state.currentRight = endRight

        // 減衰付きピークホールド（実効ゲインを反映して表示）
        let displayPeak = min(1.0, peak * max(endLeft, endRight))
        state.level = max(displayPeak, state.level * 0.82)
    }

    /// `count` 個のサンプルを `stride` おきに辿り、ゲインを掛けて書き出す。
    /// 現在値が目標と違えば 1 サンプルずつ寄せる。戻り値は最後に掛けたゲイン。
    @inline(__always)
    private static func applyGain(
        _ inPtr: UnsafePointer<Float>, _ outPtr: UnsafeMutablePointer<Float>,
        stride: Int, count: Int, from start: Float, to target: Float, step: Float
    ) -> Float {
        guard count > 0 else { return start }
        if start == target {
            if target == 1.0 && stride == 1 {
                memcpy(outPtr, inPtr, count * MemoryLayout<Float>.size)
            } else {
                var g = target
                vDSP_vsmul(inPtr, stride, &g, outPtr, stride, vDSP_Length(count))
            }
            return target
        }
        // 目標へ向かって 1 サンプルずつ寄せる。急にゲインを変えると
        // 波形が不連続になりプチッと鳴るため、必ず滑らかに変化させる。
        var g = start
        if target > start {
            for n in 0..<count {
                g = min(target, g + step)
                outPtr[n * stride] = inPtr[n * stride] * g
            }
        } else {
            for n in 0..<count {
                g = max(target, g - step)
                outPtr[n * stride] = inPtr[n * stride] * g
            }
        }
        return g
    }
}

import XCTest
import CoreAudio
@testable import AppMixer

/// IOProc の中身（ゲイン・バランス・フェード・ピーク）。HAL には触らない。
final class ProcessTapRenderTests: XCTestCase {

    /// テスト用のバッファ一式。解放は deinit で行う。
    private final class Buffers {
        let input: UnsafeMutableAudioBufferListPointer
        let output: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []
        private var sizes: [Int] = []

        /// `channels` 本のバッファに、それぞれ `samples` 個の Float を持たせる。
        init(buffers: Int, samples: [Int]) {
            input = AudioBufferList.allocate(maximumBuffers: buffers)
            output = AudioBufferList.allocate(maximumBuffers: buffers)
            for i in 0..<buffers {
                for list in [input, output] {
                    let n = samples[i]
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n))
                    p.initialize(repeating: 0, count: max(1, n))
                    storage.append(p); sizes.append(max(1, n))
                    list[i].mNumberChannels = 1
                    list[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
                    list[i].mData = UnsafeMutableRawPointer(p)
                }
            }
        }

        deinit {
            for (p, n) in zip(storage, sizes) { p.deinitialize(count: n); p.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }

        func fill(_ index: Int, _ values: [Float]) {
            let p = input[index].mData!.assumingMemoryBound(to: Float.self)
            for (i, v) in values.enumerated() { p[i] = v }
        }

        func out(_ index: Int, count: Int) -> [Float] {
            let p = output[index].mData!.assumingMemoryBound(to: Float.self)
            return (0..<count).map { p[$0] }
        }

        func render(_ state: TapState) {
            ProcessTap.render(input: UnsafePointer(input.unsafePointer),
                              output: output.unsafeMutablePointer, state: state)
        }
    }

    private func state(left: Float, right: Float, step: Float = 1,
                       channels: Int = 2, interleaved: Bool = true) -> TapState {
        let s = TapState()
        s.targetLeft = left; s.currentLeft = left
        s.targetRight = right; s.currentRight = right
        s.rampStep = step
        s.channelCount = channels
        s.isInterleaved = interleaved
        return s
    }

    // MARK: - インターリーブのステレオ

    func testUnityGainCopiesInput() {
        let b = Buffers(buffers: 1, samples: [6])
        b.fill(0, [0.1, -0.2, 0.3, -0.4, 0.5, -0.6])
        let s = state(left: 1, right: 1)
        b.render(s)
        XCTAssertEqual(b.out(0, count: 6), [0.1, -0.2, 0.3, -0.4, 0.5, -0.6])
        XCTAssertEqual(s.level, 0.6, accuracy: 1e-6)
    }

    func testUniformGainScalesBothChannels() {
        let b = Buffers(buffers: 1, samples: [4])
        b.fill(0, [1, 1, -1, -1])
        b.render(state(left: 0.5, right: 0.5))
        XCTAssertEqual(b.out(0, count: 4), [0.5, 0.5, -0.5, -0.5])
    }

    func testBalanceLeftSilencesRightChannel() {
        let b = Buffers(buffers: 1, samples: [4])
        b.fill(0, [1, 1, 1, 1])
        b.render(state(left: 1, right: 0))
        XCTAssertEqual(b.out(0, count: 4), [1, 0, 1, 0])
    }

    func testBalanceRightLowersLeftChannelOnly() {
        let b = Buffers(buffers: 1, samples: [4])
        b.fill(0, [1, 1, 1, 1])
        b.render(state(left: 0.25, right: 1))
        XCTAssertEqual(b.out(0, count: 4), [0.25, 1, 0.25, 1])
    }

    func testLevelReflectsLouderChannelGain() {
        let b = Buffers(buffers: 1, samples: [2])
        b.fill(0, [1, 1])
        let s = state(left: 0.2, right: 0.6)
        b.render(s)
        XCTAssertEqual(s.level, 0.6, accuracy: 1e-6)
    }

    // MARK: - 非インターリーブのステレオ

    func testNonInterleavedAppliesPerBufferGains() {
        let b = Buffers(buffers: 2, samples: [3, 3])
        b.fill(0, [1, 1, 1])
        b.fill(1, [1, 1, 1])
        b.render(state(left: 1, right: 0.5, interleaved: false))
        XCTAssertEqual(b.out(0, count: 3), [1, 1, 1])
        XCTAssertEqual(b.out(1, count: 3), [0.5, 0.5, 0.5])
    }

    // MARK: - バランスの無い形式

    func testMonoIgnoresRightGain() {
        let b = Buffers(buffers: 1, samples: [3])
        b.fill(0, [1, 1, 1])
        let s = state(left: 0.5, right: 0, channels: 1)
        b.render(s)
        XCTAssertEqual(b.out(0, count: 3), [0.5, 0.5, 0.5])
        XCTAssertEqual(s.currentRight, 0.5)
    }

    // MARK: - フェード

    func testGainRampsTowardTargetOneSamplePerChannel() {
        let b = Buffers(buffers: 1, samples: [8])
        b.fill(0, [1, 1, 1, 1, 1, 1, 1, 1])
        let s = state(left: 1, right: 1, step: 0.25)
        s.targetLeft = 0; s.targetRight = 0
        b.render(s)
        // 左右それぞれ 4 フレームで 1.0 -> 0 へ。
        XCTAssertEqual(b.out(0, count: 8), [0.75, 0.75, 0.5, 0.5, 0.25, 0.25, 0, 0])
        XCTAssertEqual(s.currentLeft, 0)
        XCTAssertEqual(s.currentRight, 0)
    }

    func testRampUpStopsAtTarget() {
        let b = Buffers(buffers: 1, samples: [6])
        b.fill(0, [1, 1, 1, 1, 1, 1])
        let s = state(left: 0, right: 0, step: 0.5)
        s.targetLeft = 0.75; s.targetRight = 0.75
        b.render(s)
        XCTAssertEqual(b.out(0, count: 6), [0.5, 0.5, 0.75, 0.75, 0.75, 0.75])
        XCTAssertEqual(s.currentLeft, 0.75)
    }

    func testRampContinuesAcrossCalls() {
        let b = Buffers(buffers: 1, samples: [2])
        b.fill(0, [1, 1])
        let s = state(left: 1, right: 1, step: 0.25)
        s.targetLeft = 0; s.targetRight = 0
        b.render(s)
        XCTAssertEqual(b.out(0, count: 2), [0.75, 0.75])
        b.render(s)
        XCTAssertEqual(b.out(0, count: 2), [0.5, 0.5])
        XCTAssertEqual(s.currentLeft, 0.5)
    }

    func testChannelsRampIndependently() {
        let b = Buffers(buffers: 1, samples: [4])
        b.fill(0, [1, 1, 1, 1])
        let s = state(left: 1, right: 1, step: 0.5)
        s.targetRight = 0   // 右だけ絞る
        b.render(s)
        XCTAssertEqual(b.out(0, count: 4), [1, 0.5, 1, 0])
        XCTAssertEqual(s.currentLeft, 1)
        XCTAssertEqual(s.currentRight, 0)
    }

    // MARK: - ピークホールド

    func testLevelDecaysWithSilence() {
        let b = Buffers(buffers: 1, samples: [2])
        b.fill(0, [0.5, 0.5])
        let s = state(left: 1, right: 1)
        b.render(s)
        XCTAssertEqual(s.level, 0.5, accuracy: 1e-6)
        b.fill(0, [0, 0])
        b.render(s)
        XCTAssertEqual(s.level, 0.5 * 0.82, accuracy: 1e-6)
    }

    func testLevelIsCappedAtOne() {
        let b = Buffers(buffers: 1, samples: [2])
        b.fill(0, [3, -3])
        let s = state(left: 1, right: 1)
        b.render(s)
        XCTAssertEqual(s.level, 1)
    }

    // MARK: - 境界

    func testOutputBeyondInputIsSilenced() {
        // 出力が入力より長い。前サイクルの残りを消すこと。
        let b = Buffers(buffers: 1, samples: [2])
        b.output[0].mDataByteSize = UInt32(2 * MemoryLayout<Float>.size)
        b.input[0].mDataByteSize = 0
        let p = b.output[0].mData!.assumingMemoryBound(to: Float.self)
        p[0] = 0.9; p[1] = 0.9
        b.render(state(left: 1, right: 1))
        XCTAssertEqual(b.out(0, count: 2), [0, 0])
    }

    func testMissingBuffersDoNotCrash() {
        let b = Buffers(buffers: 1, samples: [2])
        b.input[0].mData = nil
        b.render(state(left: 1, right: 1))
        XCTAssertEqual(b.out(0, count: 2), [0, 0])
    }
}

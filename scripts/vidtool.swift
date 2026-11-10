// 宣伝用の動画の仕上げ（H.264 の MP4・音なし）。
//   vidtool patch <in.mp4> <out.mp4> <背景.png> <帯の高さ px>
//     収録した動画の上の帯（メニューバー）を、コマごとに背景の PNG で塗り直す（収録中に macOS が出す紫の印を消す）。
//     背景の PNG は、動画の大きさに合わせて縮めて使う。コマの時刻はそのまま
//   vidtool concat <out.mp4> <背景.png> <帯の高さ px> <in1.mp4> <始め 秒> <終わり 秒> [<in2.mp4> <始め> <終わり> …]
//     収録した動画の指定の区間をつなぎ、上の帯を背景で塗り直す。動きの無い間はコマが無いので、区間の頭は直前のコマで埋める
//   vidtool encode <コマのフォルダ> <out.mp4> <fps> [ビットレート bps（既定 3000000）]
//     名前順の PNG / JPEG を、1 コマ 1/fps 秒の動画にする。大きさは最初のコマと同じ
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }
let args = CommandLine.arguments
guard args.count >= 5 else { fail("使い方: vidtool patch <in> <out> <背景.png> <帯 px> | vidtool encode <フォルダ> <out> <fps> [bps]") }

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("画像を読めません: \(path)") }
    return image
}

final class Writer {
    static let sRGBTransfer = kCVImageBufferTransferFunction_sRGB as String
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int
    init(path: String, width: Int, height: Int, bitrate: Int) {
        try? FileManager.default.removeItem(atPath: path)
        self.width = width; self.height = height
        do { writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4) } catch { fail("書き出せません: \(error)") }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: 60],
            // 色: コマは sRGB の値のまま入れ、動画にも「伝達関数は sRGB」と書く。既定（BT.709 の伝達関数）のままだと、
            // 暗い色が変換されて持ち上がり（#222226 の地が #26252B に見える）、同じ背景の静止画と色がそろわない
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: Writer.sRGBTransfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { fail("書き出しを始められません: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
    }
    /// draw は、左下が原点の width×height の絵を描く
    func append(at time: CMTime, draw: (CGContext) -> Void) {
        guard let pool = adaptor.pixelBufferPool else { fail("pixel buffer pool がありません") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { fail("pixel buffer を作れません") }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        draw(ctx)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { usleep(2000) }
        guard adaptor.append(buffer, withPresentationTime: time) else { fail("コマを足せません: \(String(describing: writer.error))") }
    }
    func finish(at end: CMTime? = nil) {
        input.markAsFinished()
        if let end { writer.endSession(atSourceTime: end) }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { fail("書き終えられません: \(String(describing: writer.error))") }
    }
}

switch args[1] {
case "patch":
    guard args.count == 6, let band = Int(args[5]) else { fail("使い方: vidtool patch <in> <out> <背景.png> <帯 px>") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    let backdrop = loadImage(args[4])
    let done = DispatchSemaphore(value: 0)
    Task {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("動画のトラックがありません") }
        let size = try await track.load(.naturalSize)
        let width = Int(size.width), height = Int(size.height)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); reader.startReading()
        let writer = Writer(path: args[3], width: width, height: height, bitrate: 3_000_000)
        // 背景は幅に合わせ、上端をそろえる（make-backdrop と同じ置き方）
        let backdropHeight = CGFloat(width) * CGFloat(backdrop.height) / CGFloat(backdrop.width)
        var frames = 0
        var first: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if first == nil { first = time }
            let image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height))!
            writer.append(at: time - first!) { ctx in
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: height - band, width: width, height: band))
                ctx.draw(backdrop, in: CGRect(x: 0, y: CGFloat(height) - backdropHeight, width: CGFloat(width), height: backdropHeight))
                ctx.restoreGState()
            }
            frames += 1
        }
        writer.finish()
        print("vidtool: \(frames) コマを \(args[3]) に書きました（\(width)×\(height)）")
        done.signal()
    }
    done.wait()
case "concat":
    guard args.count >= 8, (args.count - 5) % 3 == 0, let band = Int(args[4]) else { fail("使い方: vidtool concat <out> <背景.png> <帯 px> <in> <始め> <終わり> …") }
    let backdrop = loadImage(args[3])
    let ci = CIContext()
    let done = DispatchSemaphore(value: 0)
    Task {
        var writer: Writer?
        var offset = CMTime.zero
        var frames = 0
        var index = 5
        while index + 2 < args.count {
            let asset = AVURLAsset(url: URL(fileURLWithPath: args[index]))
            guard let start = Double(args[index + 1]), let end = Double(args[index + 2]), end > start else { fail("区間が読めません: \(args[index + 1]) \(args[index + 2])") }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("動画のトラックがありません: \(args[index])") }
            let size = try await track.load(.naturalSize)
            let width = Int(size.width), height = Int(size.height)
            if writer == nil { writer = Writer(path: args[2], width: width, height: height, bitrate: 3_000_000) }
            guard let writer, writer.width == width, writer.height == height else { fail("大きさの違う動画はつなげません: \(args[index])") }
            let backdropHeight = CGFloat(width) * CGFloat(backdrop.height) / CGFloat(backdrop.width)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); reader.startReading()
            func emit(_ image: CGImage, at seconds: Double) {
                writer.append(at: offset + CMTime(seconds: seconds, preferredTimescale: 600)) { ctx in
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: 0, y: height - band, width: width, height: band))
                    ctx.draw(backdrop, in: CGRect(x: 0, y: CGFloat(height) - backdropHeight, width: CGFloat(width), height: backdropHeight))
                    ctx.restoreGState()
                }
                frames += 1
            }
            var first: CMTime?
            var held: CGImage?
            var began = false
            while let sample = output.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
                if first == nil { first = stamp }
                let time = (stamp - first!).seconds
                if time >= end { break }
                guard let image = ci.createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height)) else { continue }
                if time < start { held = image; continue }
                if !began {
                    began = true
                    if time > start + 0.001, let held { emit(held, at: 0) }
                }
                emit(image, at: time - start)
            }
            if !began, let held { emit(held, at: 0) }
            reader.cancelReading()
            offset = offset + CMTime(seconds: end - start, preferredTimescale: 600)
            index += 3
        }
        writer?.finish(at: offset)
        print("vidtool: \(frames) コマ・\(String(format: "%.2f", offset.seconds)) 秒を \(args[2]) に書きました")
        done.signal()
    }
    done.wait()
case "encode":
    guard let fps = Int32(args[4]), fps > 0 else { fail("fps は正の整数で") }
    let bitrate = args.count > 5 ? Int(args[5]) ?? 3_000_000 : 3_000_000
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: args[2])) ?? []).filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }.sorted()
    guard let firstName = names.first else { fail("コマがありません: \(args[2])") }
    let firstImage = loadImage(args[2] + "/" + firstName)
    let writer = Writer(path: args[3], width: firstImage.width, height: firstImage.height, bitrate: bitrate)
    for (index, name) in names.enumerated() {
        autoreleasepool {
            let image = index == 0 ? firstImage : loadImage(args[2] + "/" + name)
            writer.append(at: CMTime(value: CMTimeValue(index), timescale: fps)) { ctx in
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: writer.width, height: writer.height))
            }
        }
    }
    writer.finish()
    print("vidtool: \(names.count) コマを \(args[3]) に書きました（\(firstImage.width)×\(firstImage.height)・\(fps)fps）")
default:
    fail("patch か encode を指定してください")
}

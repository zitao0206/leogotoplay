import AVFoundation
import CoreImage
import Foundation
import UIKit

/// V3.7：一键视频增强的两个方向，可多选。
enum EnhanceOption: String, CaseIterable, Identifiable {
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "音质优化"
        case .video: return "画面优化"
        }
    }

    var summary: String {
        switch self {
        case .audio: return "降噪 / 去混响"
        case .video: return "提亮、去灰、锐化"
        }
    }

    var detail: String {
        switch self {
        case .audio:
            return "压掉空调声、风声这类底噪，滤掉低频轰鸣，顺手压一下混响尾巴，最后把整段音量拉到同一水平。"
        case .video:
            return "逐帧微调亮度、对比度和饱和度，再叠一层轻锐化，暗部发灰、画面发闷的素材会通透一些。"
        }
    }

    var symbol: String {
        switch self {
        case .audio: return "waveform.badge.mic"
        case .video: return "camera.filters"
        }
    }
}

enum EnhancePrefs {
    static let audioKey = "enhance.audio"
    static let videoKey = "enhance.video"
}

struct EnhanceResult {
    let url: URL
    let duration: Double
    let didAudio: Bool
    let didVideo: Bool
}

enum EnhanceError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case audioFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频画面"
        case .readerFailed(let reason): return "读取视频失败：\(reason)"
        case .writerFailed(let reason): return "写出视频失败：\(reason)"
        case .audioFailed(let reason): return "处理声音失败：\(reason)"
        case .cancelled: return "已取消"
        }
    }
}

/// 音轨的原始采样参数：不再硬编码 44100/2ch，单声道素材也不会被错位处理。
struct AudioFormat {
    let sampleRate: Float
    let channels: Int

    static let `default` = AudioFormat(sampleRate: 44100, channels: 2)

    static func of(_ track: AVAssetTrack) -> AudioFormat {
        guard let any = track.formatDescriptions.first else { return .default }
        let generic = any as! CMFormatDescription
        guard CMFormatDescriptionGetMediaType(generic) == kCMMediaType_Audio else { return .default }
        let audio = generic as! CMAudioFormatDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audio)?.pointee else {
            return .default
        }
        let rate = Float(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)
        guard rate >= 8000, rate <= 96000, channels >= 1 else { return .default }
        return AudioFormat(sampleRate: rate, channels: min(channels, 2))
    }
}

enum VideoEnhancer {

    /// 经验估时：画面逐帧处理占大头，声音处理便宜一些。
    static func estimate(duration: Double, options: Set<EnhanceOption>) -> Double {
        var seconds = 1.2
        if options.contains(.video) { seconds += duration * 0.85 }
        else { seconds += duration * 0.12 }
        if options.contains(.audio) { seconds += duration * 0.30 }
        return seconds
    }

    static func estimateLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "约 \(Int(seconds.rounded(.up))) 秒" }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if rest == 0 { return "约 \(minutes) 分钟" }
        return "约 \(minutes) 分 \(rest) 秒"
    }

    /// 三步走：先把声音单独处理成一个 m4a（音轨、视频轨分开写，避免 AVAssetWriter
    /// 逐时间点交错时互相等待锁死），再逐帧重写画面，最后用 passthrough 导出把两轨封到一起。
    static func run(
        url: URL,
        options: Set<EnhanceOption>,
        onProgress: @escaping (Double) -> Void
    ) async throws -> EnhanceResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw EnhanceError.noVideoTrack
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let wantsAudio = options.contains(.audio)
        let wantsVideo = options.contains(.video)
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let hasAudio = wantsAudio && audioTrack != nil
        let audioFormat = audioTrack.map { AudioFormat.of($0) } ?? .default

        // MARK: 1. 声音
        var processedAudioURL: URL?
        if hasAudio, let audioTrack {
            processedAudioURL = try processAudio(
                asset: asset,
                track: audioTrack,
                format: audioFormat,
                duration: duration,
                progressSpan: 0...(wantsVideo ? 0.34 : 0.92),
                onProgress: onProgress
            )
        } else {
            onProgress(wantsVideo ? 0.02 : 0.05)
        }

        // MARK: 2. 画面（只做声音时视频轨原样透传，不再逐帧重编码，少一次代际损失）
        var videoURL: URL?
        if wantsVideo {
            videoURL = try writeVideo(
                asset: asset,
                track: videoTrack,
                duration: duration,
                applyLook: true,
                progressSpan: hasAudio ? 0.34...0.92 : 0.05...0.92,
                onProgress: onProgress
            )
            onProgress(0.92)
        }

        // MARK: 3. 封装
        onProgress(0.95)
        do {
            let finalURL = try await mux(videoURL: videoURL, audioFile: processedAudioURL, asset: asset)
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            if let processedAudioURL { try? FileManager.default.removeItem(at: processedAudioURL) }
            onProgress(1)
            return EnhanceResult(
                url: finalURL,
                duration: duration,
                didAudio: hasAudio,
                didVideo: wantsVideo
            )
        } catch {
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            if let processedAudioURL { try? FileManager.default.removeItem(at: processedAudioURL) }
            throw error
        }
    }

    // MARK: - 画面

    private static func writeVideo(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: Double,
        applyLook: Bool,
        progressSpan: ClosedRange<Double>,
        onProgress: @escaping (Double) -> Void
    ) throws -> URL {
        let transform = track.preferredTransform
        let naturalSize = track.naturalSize
        let orientedSize = transform.isQuarterTurn
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let nominalFPS = max(track.nominalFrameRate, 1)
        let totalFrames = max(Int((duration * Double(nominalFPS)).rounded()), 1)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw EnhanceError.readerFailed("无法读取视频轨道")
        }
        reader.add(videoOutput)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-video-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = Int(orientedSize.width.rounded())
        let height = Int(orientedSize.height.rounded())
        let bitrate = max(Int(Double(width * height) * Double(nominalFPS) * 0.12), 2_500_000)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw EnhanceError.writerFailed("无法写入视频轨道")
        }
        writer.add(videoInput)

        guard writer.startWriting(), reader.startReading() else {
            throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "无法开始")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        var frameIndex = 0

        while let sample = videoOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw EnhanceError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)

            try autoreleasepool {
                var image = CIImage(cvPixelBuffer: pixelBuffer)
                if !transform.isIdentity {
                    image = image.transformed(by: transform)
                    let extent = image.extent
                    if extent.origin != .zero {
                        image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
                    }
                }
                image = image.cropped(to: CGRect(origin: .zero, size: orientedSize))
                if applyLook {
                    image = applyLookFilter(image)
                }

                if let pool = adaptor.pixelBufferPool {
                    var target: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess,
                          let target else { return }
                    context.render(image, to: target,
                                   bounds: CGRect(origin: .zero, size: orientedSize),
                                   colorSpace: CGColorSpaceCreateDeviceRGB())

                    var waited = 0
                    while !videoInput.isReadyForMoreMediaData {
                        usleep(3000)
                        waited += 1
                        if waited > 2000 {
                            throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? "写入器长时间不接受数据")
                        }
                    }
                    if adaptor.append(target, withPresentationTime: presentation) == false {
                        throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? "追加画面失败")
                    }
                }
            }

            frameIndex += 1
            if frameIndex % 4 == 0 {
                let ratio = min(Double(frameIndex) / Double(max(totalFrames, 1)), 1)
                let value = progressSpan.lowerBound + (progressSpan.upperBound - progressSpan.lowerBound) * ratio
                onProgress(min(value, progressSpan.upperBound))
            }
        }

        videoInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw EnhanceError.writerFailed(writer.error?.localizedDescription ?? "写入未完成")
        }
        return outputURL
    }

    private static func applyLookFilter(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.12])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.12,
                kCIInputSaturationKey: 1.08,
                kCIInputBrightnessKey: 0.015
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.35
            ])
    }

    // MARK: - 声音

    /// 两遍走：第一遍只跑高通量出**原始**峰值（不经过噪声门，避免门控压小峰值后补增益失真），
    /// 第二遍按同一套处理再算一遍并按增益写出去，这样又不用把几十兆的浮点采样堆在内存里。
    private static func processAudio(
        asset: AVURLAsset,
        track: AVAssetTrack,
        format: AudioFormat,
        duration: Double,
        progressSpan: ClosedRange<Double>,
        onProgress: @escaping (Double) -> Void
    ) throws -> URL {
        let peak = try measureAudio(asset: asset, track: track, format: format, duration: duration) { ratio in
            let span = progressSpan.upperBound - progressSpan.lowerBound
            onProgress(progressSpan.lowerBound + span * 0.45 * ratio)
        }
        // 上限从 8 倍放宽到 20 倍（+26 dB）：小音量素材才真的能被拉到 0.9，而不是卡在固定 +1.6 dB
        let gain: Float = peak > 0.0001 ? min(0.9 / peak, 20) : 1

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-audio-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(format.sampleRate),
            AVNumberOfChannelsKey: format.channels,
            AVEncoderBitRateKey: 96_000 * format.channels
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw EnhanceError.audioFailed("无法写入音轨")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw EnhanceError.audioFailed(writer.error?.localizedDescription ?? "无法开始写音轨")
        }
        writer.startSession(atSourceTime: .zero)

        let (reader, output) = try makePCMReader(asset: asset, track: track, format: format)
        guard reader.startReading() else {
            throw EnhanceError.audioFailed(reader.error?.localizedDescription ?? "无法读取声音")
        }

        var chain = AudioChain(sampleRate: format.sampleRate, channels: format.channels)

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw EnhanceError.cancelled
            }
            guard let converted = convert(sample: sample, chain: &chain, gain: gain) else { continue }

            var waited = 0
            while !input.isReadyForMoreMediaData {
                usleep(3000)
                waited += 1
                if waited > 2000 {
                    throw EnhanceError.audioFailed(writer.error?.localizedDescription ?? "音轨写入长时间无响应")
                }
            }
            if input.append(converted) == false {
                throw EnhanceError.audioFailed(writer.error?.localizedDescription ?? "追加声音失败")
            }

            let span = progressSpan.upperBound - progressSpan.lowerBound
            let ratio = duration > 0
                ? min(max(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 0), 1)
                : 0
            let value = progressSpan.lowerBound + span * 0.45 + span * 0.55 * ratio
            onProgress(min(value, progressSpan.upperBound))
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw EnhanceError.audioFailed(writer.error?.localizedDescription ?? "音轨写入未完成")
        }
        onProgress(progressSpan.upperBound)
        return outputURL
    }

    private static func measureAudio(
        asset: AVURLAsset,
        track: AVAssetTrack,
        format: AudioFormat,
        duration: Double,
        onProgress: @escaping (Double) -> Void
    ) throws -> Float {
        let (reader, output) = try makePCMReader(asset: asset, track: track, format: format)
        guard reader.startReading() else {
            throw EnhanceError.audioFailed(reader.error?.localizedDescription ?? "无法读取声音")
        }
        var chain = AudioChain(sampleRate: format.sampleRate, channels: format.channels)
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw EnhanceError.cancelled
            }
            guard let values = floats(from: sample, chain: &chain, applyGate: false) else { continue }
            for value in values { peak = max(peak, abs(value)) }
            let ratio = duration > 0
                ? min(max(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 0), 1)
                : 0
            onProgress(ratio)
        }
        return peak
    }

    private static func makePCMReader(
        asset: AVURLAsset,
        track: AVAssetTrack,
        format: AudioFormat
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Double(format.sampleRate),
            AVNumberOfChannelsKey: format.channels
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw EnhanceError.audioFailed("无法读取声音轨道")
        }
        reader.add(output)
        return (reader, output)
    }

    /// 读出浮点采样并跑一遍 DSP。`applyGate == false` 时只走高通，用来量原始峰值。
    /// 用 CopyDataBytes 而不是 GetDataPointer：分块缓冲也能安全读，不会越界。
    private static func floats(
        from sample: CMSampleBuffer,
        chain: inout AudioChain,
        applyGate: Bool = true
    ) -> [Float]? {
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let byteCount = CMBlockBufferGetDataLength(data)
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard byteCount > 0,
              byteCount % MemoryLayout<Float>.size == 0,
              frameCount > 0
        else { return nil }

        let bytesPerFrame = byteCount / frameCount
        guard bytesPerFrame > 0, bytesPerFrame % MemoryLayout<Float>.size == 0 else { return nil }
        let channels = bytesPerFrame / MemoryLayout<Float>.size

        if let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            chain.match(sampleRate: Float(asbd.mSampleRate), channels: channels)
        } else {
            chain.match(sampleRate: chain.sampleRate, channels: channels)
        }

        var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        let copied = CMBlockBufferCopyDataBytes(
            data,
            atOffset: 0,
            dataLength: byteCount,
            destination: &values
        )
        guard copied == kCMBlockBufferNoErr, !values.isEmpty else { return nil }
        if applyGate { chain.process(&values) } else { chain.processRaw(&values) }
        return values
    }

    /// 处理完一段并把 PCM 重新打包成 CMSampleBuffer（保留原时间戳，交给 writer 压 AAC）
    private static func convert(sample: CMSampleBuffer, chain: inout AudioChain, gain: Float) -> CMSampleBuffer? {
                guard let values = floats(from: sample, chain: &chain),
              let format = CMSampleBufferGetFormatDescription(sample)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0 else { return nil }
        let byteCount = values.count * MemoryLayout<Float>.size
        guard byteCount % frameCount == 0 else { return nil }
        let bytesPerFrame = byteCount / frameCount

        // 自己 malloc 一块内存交给 CMBlockBuffer 托管（kCFAllocatorMalloc 会负责 free），
        // 直接写入处理后的采样，避免对未分配的空 block 取指针失败
        guard let raw = malloc(byteCount) else { return nil }
        let destination = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<values.count { destination[i] = softLimit(values[i] * gain) }

        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: raw,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard createStatus == kCMBlockBufferNoErr, let block else {
            free(raw)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(chain.sampleRate.rounded())),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var sizeArray = [bytesPerFrame]
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizeArray,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - 封装

    private static func mux(videoURL: URL?, audioFile: URL?, asset: AVURLAsset) async throws -> URL {
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: finalURL)

        let composition = AVMutableComposition()
        // videoURL == nil 表示只做声音，画面直接用原片透传，不经过任何重编码
        let videoSource = videoURL.map { AVURLAsset(url: $0) } ?? asset
        guard let sourceVideo = videoSource.tracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw EnhanceError.writerFailed("无法组装画面轨道")
        }
        let videoRange = sourceVideo.timeRange
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)

        let audioSource: AVURLAsset? = {
            if let audioFile { return AVURLAsset(url: audioFile) }
            if asset.tracks(withMediaType: .audio).first != nil { return asset }
            return nil
        }()
        if let audioSource,
           let sourceAudio = audioSource.tracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = CMTimeMinimum(sourceAudio.timeRange.duration, videoRange.duration)
            if audioDuration > .zero {
                try? audioTrack.insertTimeRange(
                    CMTimeRange(start: sourceAudio.timeRange.start, duration: audioDuration),
                    of: sourceAudio,
                    at: .zero
                )
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw EnhanceError.writerFailed("无法创建导出会话")
        }
        export.outputURL = finalURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }

        if export.status != .completed {
            try? FileManager.default.removeItem(at: finalURL)
            throw EnhanceError.writerFailed(export.error?.localizedDescription ?? "封装失败")
        }
        return finalURL
    }
}

/// 软限幅：增益在门控之后施加，这里兜住 0.92 以上，避免瞬间尖峰顶到 1.0 爆掉。
@inline(__always)
private func softLimit(_ value: Float, ceiling: Float = 0.92) -> Float {
    let magnitude = abs(value)
    guard magnitude > ceiling else { return value }
    let sign: Float = value >= 0 ? 1 : -1
    let room = max(1 - ceiling, 0.001)
    let compressed = ceiling + room * (1 - exp(-(magnitude - ceiling) / room))
    return sign * compressed
}

/// 轻量 DSP 链：高通 → 噪声门（压底噪、收混响尾巴）。增益和限幅放在链外，先归一化再限幅。
private struct AudioChain {
    private(set) var sampleRate: Float
    private(set) var channels: Int
    private var highpass: [Biquad]
    private var envelope: [Float]
    private var gate: Float = 1
    private var noiseFloor: Float = 0.02

    // 时间常数一律按「秒」定义、按真实采样率换算。原来的 0.0008 / 0.98 是按“每缓冲”写的，
    // 但这里是逐采样处理，44100 次/秒会把 15 ms 的包络拉成 0.7 ms，整套估计于是失去意义。
    private let envDecay: Float    // 包络回落 15 ms
    private let floorFall: Float   // 环境变安静时 30 ms 跟下来
    private let floorRise: Float   // 环境变吵时最多 0.5 dB/s 慢慢爬
    private let gateSmooth: Float  // 门增益平滑 8 ms

    init(sampleRate: Float, channels: Int) {
        let count = max(channels, 1)
        let fs = max(sampleRate, 8000)
        self.sampleRate = sampleRate
        self.channels = count
        highpass = Array(repeating: Biquad.highpass(cutoff: 90, sampleRate: fs), count: count)
        envelope = Array(repeating: 0, count: count)
        envDecay = exp(-1 / (0.015 * fs))
        floorFall = exp(-1 / (0.030 * fs))
        floorRise = pow(10, 0.5 / 20 / fs)
        gateSmooth = 1 - exp(-1 / (0.008 * fs))
    }

    /// 采样格式和预期不一致时重建滤波器状态，避免把单声道数据当成双声道错位处理
    mutating func match(sampleRate: Float, channels: Int) {
        guard abs(sampleRate - self.sampleRate) > 1 || channels != self.channels else { return }
        self = AudioChain(sampleRate: sampleRate, channels: channels)
    }

    mutating func process(_ samples: inout [Float]) {
        guard channels > 0 else { return }

        var index = 0
        while index + channels <= samples.count {
            var framePeak: Float = 0
            for channel in 0..<channels {
                let value = highpass[channel].process(samples[index + channel])
                samples[index + channel] = value
                let magnitude = abs(value)
                envelope[channel] = max(magnitude, envelope[channel] * envDecay)
                framePeak = max(framePeak, envelope[channel])
            }

            // 噪声底：有界、快降慢升。安静时按 30 ms 跟下来，变吵时最多 0.5 dB/s 爬上去，
            // 且永远不超过当前包络，不会像原来那样上下界都乘法增长、1 秒内发散到 1e14。
            if framePeak <= noiseFloor {
                noiseFloor = max(framePeak, noiseFloor * floorFall)
            } else {
                noiseFloor = min(framePeak, noiseFloor * floorRise)
            }

            // 连续型下行扩展：环境噪声附近压到 −9 dB，人声/有效信号进来立刻回到 0 dB。
            // 用连续映射 + 8 ms 平滑，避免硬开关带来的“抽气”声。
            let ratio = framePeak / max(noiseFloor, 0.0004)
            let target: Float = min(max(0.35, ratio * 0.4), 1)
            gate += (target - gate) * gateSmooth

            for channel in 0..<channels {
                samples[index + channel] *= gate
            }

            index += channels
        }
    }

    /// 只走高通，不推进包络、不过门控，用来测量原始峰值
    mutating func processRaw(_ samples: inout [Float]) {
        guard channels > 0 else { return }
        var index = 0
        while index + channels <= samples.count {
            for channel in 0..<channels {
                samples[index + channel] = highpass[channel].process(samples[index + channel])
            }
            index += channels
        }
    }
}

/// 二阶高通（RBJ 公式），滤掉低频轰鸣。
private struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0

    static func highpass(cutoff: Float, sampleRate: Float) -> Biquad {
        let w0 = 2 * Float.pi * cutoff / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * 0.707)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cosw) / 2) / a0,
            b1: (-(1 + cosw)) / a0,
            b2: ((1 + cosw) / 2) / a0,
            a1: (-2 * cosw) / a0,
            a2: (1 - alpha) / a0
        )
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}

private extension CGAffineTransform {
    var isQuarterTurn: Bool {
        let angle = atan2(b, a)
        let degrees = Int((angle * 180 / .pi).rounded())
        return abs(degrees) == 90 || abs(degrees) == 270
    }
}

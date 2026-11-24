import AVFoundation
import LeogotoPlayCore
import Speech
import Vision

/// V3.5：一键提取文字。两条来源：
/// 1. 画面：按 0.5s 抽帧走 Vision 文字识别，连续相同的字幕合并成一条；
/// 2. 声音：导出音轨后按 30s 切片喂端上语音识别，按片段时间码还原到全片。
enum TextExtractPrefs {
    static let framesKey = "text.extract.frames"
    static let speechKey = "text.extract.speech"
}

struct ExtractedLine: Identifiable {
    enum Source: String {
        case screen = "画面文字"
        case speech = "语音转写"
    }

    let id = UUID()
    var start: Double
    var end: Double
    var text: String
    var source: Source

    var timeLabel: String {
        func stamp(_ value: Double) -> String {
            let total = Int(value)
            let m = total / 60
            let s = total % 60
            return String(format: "%02d:%02d", m, s)
        }
        return "\(stamp(start)) – \(stamp(end))"
    }
}

struct TextExtractResult {
    var lines: [ExtractedLine]
    var warnings: [String]

    /// 复制到剪贴板用：只留文字，不带时间码
    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var screenCount: Int { lines.filter { $0.source == .screen }.count }
    var speechCount: Int { lines.filter { $0.source == .speech }.count }
}

enum TextExtractError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case speechUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个视频没有可识别的画面轨道"
        case .noAudioTrack: return "这个视频没有音轨，无法做声音转文字"
        case .speechUnavailable(let reason): return "语音识别不可用：\(reason)"
        }
    }
}

enum TextExtractor {

    // MARK: - 估时

    /// 粗估耗时（真机量级：画面识别约 0.06×时长；端上转写约 1.1×时长）
    static func estimate(duration: Double, includeScreen: Bool, includeSpeech: Bool) -> TimeInterval {
        var seconds: TimeInterval = 1.5
        if includeScreen { seconds += duration * 0.06 }
        if includeSpeech {
            // 端上识别还要算上音轨导出，按 1.2× 时长给
            seconds += duration * 1.2
        }
        return max(3, seconds)
    }

    static func estimateLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "约 \(total) 秒" }
        let m = total / 60
        let r = total % 60
        return r == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(r) 秒"
    }

    // MARK: - 主流程

    /// - Parameters:
    ///   - onProgress: 进度 0...1 + 当前步骤文案，从后台线程回调
    static func run(
        url: URL,
        includeScreen: Bool,
        includeSpeech: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> TextExtractResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        let framesTotal = includeScreen ? max(1, Int(duration / 0.5)) : 0
        let speechChunks = includeSpeech ? max(1, Int(ceil(duration / 30.0))) : 0
        let screenWeight = includeScreen ? (includeSpeech ? 0.35 : 1.0) : 0.0
        let speechWeight = includeSpeech ? (includeScreen ? 0.65 : 1.0) : 0.0

        var lines: [ExtractedLine] = []
        var warnings: [String] = []

        if includeScreen {
            let screen = try screenLines(url: url, duration: duration, total: framesTotal) { value in
                onProgress(value * screenWeight, "正在识别画面文字")
            }
            lines.append(contentsOf: screen)
        }

        if includeSpeech {
            do {
                let speech = try await speechLines(url: url, duration: duration, chunks: speechChunks) { value in
                    onProgress(screenWeight + value * speechWeight, "正在转写声音")
                }
                lines.append(contentsOf: speech)
            } catch {
                // 语音失败不影响画面文字的结果，最后在结果里说明
                warnings.append(error.localizedDescription)
            }
        }

        lines.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        onProgress(1.0, "提取完成")
        return TextExtractResult(lines: lines, warnings: warnings)
    }

    // MARK: - 画面文字

    private static func screenLines(
        url: URL,
        duration: Double,
        total: Int,
        onProgress: @escaping (Double) -> Void
    ) throws -> [ExtractedLine] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw TextExtractError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TextExtractError.noVideoTrack
        }

        let orientation = videoOrientation(for: track.preferredTransform)
        let step = 0.5
        var nextSampleTime = 0.0
        var processed = 0
        var lines: [ExtractedLine] = []

        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.001 >= nextSampleTime else { continue }
            nextSampleTime = time + step

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let text = recognize(in: pixelBuffer, orientation: orientation)
            processed += 1
            onProgress(Double(processed) / Double(max(total, 1)))

            guard !text.isEmpty else { continue }
            if var last = lines.last, normalize(last.text) == normalize(text) {
                // 同一句字幕连续出现：延长它的结束时间，不重复输出
                last.end = min(duration, time + step)
                lines[lines.count - 1] = last
            } else {
                lines.append(ExtractedLine(start: time, end: min(duration, time + step), text: text, source: .screen))
            }
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }
        return lines
    }

    private static func recognize(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            // 从上到下拼行
            lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 视频轨道带旋转时，识别要把画面转正，否则竖屏视频会整段漏字
    private static func videoOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let radians = atan2(transform.b, transform.a)
        let degrees = Int((radians * 180 / .pi).rounded())
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - 声音转文字

    private static func speechLines(
        url: URL,
        duration: Double,
        chunks: Int,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [ExtractedLine] {
        guard await requestSpeechPermission() else {
            throw TextExtractError.speechUnavailable("没有语音识别权限")
        }
        guard let (recognizer, onDevice) = preferredRecognizer() else {
            throw TextExtractError.speechUnavailable("当前设备没有可用的语音识别语种")
        }

        let asset = AVURLAsset(url: url)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            throw TextExtractError.noAudioTrack
        }

        let audioURL = try await exportAudio(from: asset)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let chunkSeconds = 30.0
        let chunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)

        var lines: [ExtractedLine] = []
        var offset: Double = 0
        var index = 0

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(Double(chunkFrames), Double(remaining)))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }

            let segments = await recognizeChunk(
                buffer: buffer,
                recognizer: recognizer,
                onDevice: onDevice,
                timeout: chunkSeconds * 3 + 20
            )
            for segment in segments where !segment.text.isEmpty {
                lines.append(ExtractedLine(
                    start: offset + segment.start,
                    end: min(duration, offset + segment.end),
                    text: segment.text,
                    source: .speech
                ))
            }

            offset += Double(buffer.frameLength) / format.sampleRate
            index += 1
            onProgress(min(1, Double(index) / Double(max(chunks, 1))))
        }
        return lines
    }

    private static func exportAudio(from asset: AVURLAsset) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("text-extract-audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TextExtractError.noAudioTrack
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw TextExtractError.speechUnavailable(session.error?.localizedDescription ?? "音轨导出失败")
        }
        return outputURL
    }

    private static func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// 先挑支持端上识别的语种（离线、不上传）；没有端上模型时退回在线识别
    private static func preferredRecognizer() -> (recognizer: SFSpeechRecognizer, onDevice: Bool)? {
        let candidates = ["zh-CN", "zh-Hans-CN", "en-US", "en-GB"]
        for identifier in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.supportsOnDeviceRecognition {
                return (recognizer, true)
            }
        }
        for identifier in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.isAvailable {
                return (recognizer, false)
            }
        }
        return nil
    }

    private struct Segment {
        var start: Double
        var end: Double
        var text: String
    }

    /// 识别结果是词级片段，按停顿（>0.7s）合并成句子，中文不留空格、英文补空格
    private static func mergeIntoSentences(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = merged.last, segment.start - last.end <= 0.7 {
                if needsSpace(between: last.text, and: text) {
                    last.text += " "
                }
                last.text += text
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(Segment(start: segment.start, end: segment.end, text: text))
            }
        }
        return merged
    }

    private static func needsSpace(between lhs: String, and rhs: String) -> Bool {
        guard let left = lhs.last, let right = rhs.first else { return false }
        return left.isASCII && right.isASCII && !left.isPunctuation && !right.isPunctuation
    }

    private static func recognizeChunk(
        buffer: AVAudioPCMBuffer,
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        timeout: Double
    ) async -> [Segment] {
        await withCheckedContinuation { continuation in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = onDevice
            request.shouldReportPartialResults = false
            request.taskHint = .dictation

            let lock = NSLock()
            var finished = false
            func finish(_ segments: [Segment]) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(returning: segments)
            }

            let task = recognizer.recognitionTask(with: request) { result, _ in
                guard let result, result.isFinal else { return }
                let raw = result.bestTranscription.segments.map {
                    Segment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                }
                finish(mergeIntoSentences(raw))
            }

            request.append(buffer)
            request.endAudio()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                task.cancel()
                finish([])
            }
        }
    }
}

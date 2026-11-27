import AppKit
import AVFoundation
import LeogotoPlayCore
import Speech
import SwiftUI
import Vision

// MARK: - 数据

enum MacTextExtractPrefs {
    static let framesKey = "text.extract.frames"
    static let speechKey = "text.extract.speech"
}

struct MacExtractedLine: Identifiable {
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

struct MacTextExtractResult {
    var lines: [MacExtractedLine]
    var warnings: [String]

    var plainText: String { lines.map(\.text).joined(separator: "\n") }
    var screenCount: Int { lines.filter { $0.source == .screen }.count }
    var speechCount: Int { lines.filter { $0.source == .speech }.count }

    /// 带时间码的 txt，导出用
    var stampedText: String {
        lines.map { "[\($0.timeLabel)] \($0.source.rawValue) \($0.text)" }.joined(separator: "\n")
    }
}

enum MacTextExtractError: LocalizedError {
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

// MARK: - 提取器

enum MacTextExtractor {

    // MARK: 估时

    /// macOS 端比 iOS 快：画面识别按 0.04×时长，声音转写按 0.8×时长
    static func estimate(duration: Double, includeScreen: Bool, includeSpeech: Bool) -> TimeInterval {
        var seconds: TimeInterval = 1.5
        if includeScreen { seconds += duration * 0.04 }
        if includeSpeech { seconds += duration * 0.8 }
        return max(3, seconds)
    }

    static func estimateLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "约 \(total) 秒" }
        let m = total / 60
        let r = total % 60
        return r == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(r) 秒"
    }

    // MARK: 主流程

    static func run(
        url: URL,
        includeScreen: Bool,
        includeSpeech: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> MacTextExtractResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        let framesTotal = includeScreen ? max(1, Int(duration / 0.5)) : 0
        let speechChunks = includeSpeech ? max(1, Int(ceil(duration / 30.0))) : 0
        let screenWeight = includeScreen ? (includeSpeech ? 0.35 : 1.0) : 0.0
        let speechWeight = includeSpeech ? (includeScreen ? 0.65 : 1.0) : 0.0

        var lines: [MacExtractedLine] = []
        var warnings: [String] = []

        if includeScreen {
            let screen = try await screenLines(url: url, duration: duration, total: framesTotal) { value in
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
                // 语音失败不推翻画面文字的结果
                warnings.append(error.localizedDescription)
            }
        }

        lines.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        onProgress(1.0, "提取完成")
        return MacTextExtractResult(lines: lines, warnings: warnings)
    }

    // MARK: 画面文字

    private static func screenLines(
        url: URL,
        duration: Double,
        total: Int,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [MacExtractedLine] {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            throw MacTextExtractError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MacTextExtractError.noVideoTrack
        }

        let orientation = videoOrientation(for: (try? await track.load(.preferredTransform)) ?? .identity)
        let step = 0.5
        var nextSampleTime = 0.0
        var processed = 0
        var lines: [MacExtractedLine] = []

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw MacTextExtractError.noVideoTrack
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.001 >= nextSampleTime else { continue }
            nextSampleTime = time + step

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let text = autoreleasepool { recognize(in: pixelBuffer, orientation: orientation) }
            processed += 1
            onProgress(Double(processed) / Double(max(total, 1)))

            guard !text.isEmpty else { continue }
            if var last = lines.last, nearlySame(last.text, text) {
                // 同一句字幕连续出现（OCR 会抖一两个字）：留更完整的那句，只延长结束时间
                if normalize(text).count > normalize(last.text).count { last.text = text }
                last.end = min(duration, time + step)
                lines[lines.count - 1] = last
            } else {
                lines.append(MacExtractedLine(start: time, end: min(duration, time + step), text: text, source: .screen))
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
            lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// 连续字幕的抖动容忍：长度差 ≤ 3 且编辑距离 ≤ 2 视为同一句
    private static func nearlySame(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalize(lhs)
        let b = normalize(rhs)
        if a == b { return true }
        let la = a.count
        let lb = b.count
        // 字幕逐字浮现：短句整段落在长句里，也算同一句
        if min(la, lb) >= 4, abs(la - lb) > 3 {
            return la > lb ? a.contains(b) : b.contains(a)
        }
        guard abs(la - lb) <= 3, min(la, lb) >= 4 else { return false }
        return editDistance(a, b, limit: 2) <= 2
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: 声音转文字

    private static func speechLines(
        url: URL,
        duration: Double,
        chunks: Int,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [MacExtractedLine] {
        guard await requestSpeechPermission() else {
            throw MacTextExtractError.speechUnavailable("系统里没有允许语音识别（可在 系统设置 › 隐私与安全性 › 语音识别 里打开）")
        }
        let candidates = speechCandidates()
        guard let first = candidates.first else {
            throw MacTextExtractError.speechUnavailable("当前机器没有可用的语音识别语种")
        }

        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false else {
            throw MacTextExtractError.noAudioTrack
        }

        let audioURL = try await exportAudio(from: asset)
        debugLog("speech audio exported \(audioURL.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat

        // 先拿前 10 秒试两种语言，谁认出来的字多就用谁（英语片用中文模型只会出乱码）
        var chosen = first
        if candidates.count > 1 {
            var bestScore = -1
            for candidate in candidates {
                let probe = try? probeBuffer(url: audioURL, seconds: 10)
                guard let probe else { break }
                let segments = await recognizeChunk(
                    buffer: probe,
                    recognizer: candidate.recognizer,
                    onDevice: candidate.onDevice,
                    timeout: 40
                )
                let score = segments.reduce(0) { $0 + $1.text.count }
                if score > bestScore {
                    bestScore = score
                    chosen = candidate
                }
            }
        }
        let recognizer = chosen.recognizer
        let onDevice = chosen.onDevice
        debugLog("recognizer locale=\(recognizer.locale.identifier) onDevice=\(onDevice) available=\(recognizer.isAvailable)")

        let chunkSeconds = 30.0
        let chunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)

        var lines: [MacExtractedLine] = []
        var offset: Double = 0
        var index = 0

        while file.framePosition < file.length {
            if Task.isCancelled { throw CancellationError() }
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(Double(chunkFrames), Double(remaining)))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }

            let segments = await recognizeChunk(
                buffer: buffer,
                recognizer: recognizer,
                onDevice: onDevice,
                timeout: chunkSeconds * 2 + 20
            )
            for segment in segments where !segment.text.isEmpty {
                lines.append(MacExtractedLine(
                    start: offset + segment.start,
                    end: min(duration, offset + segment.end),
                    text: segment.text,
                    source: .speech
                ))
            }

            offset += Double(buffer.frameLength) / format.sampleRate
            index += 1
            debugLog("chunk \(index) -> \(segments.count) segments")
            onProgress(min(1, Double(index) / Double(max(chunks, 1))))
        }
        debugLog("speech done lines=\(lines.count)")
        return lines
    }

    static func debugLog(_ text: String) {
        #if DEBUG
        let url = URL(fileURLWithPath: "/tmp/text_extract_debug.log")
        let line = text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private static func exportAudio(from asset: AVURLAsset) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-text-extract-audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MacTextExtractError.noAudioTrack
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw MacTextExtractError.speechUnavailable(session.error?.localizedDescription ?? "音轨导出失败")
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

    /// 语音识别候选：中文、英文各一个，在线优先（准确度高），没网络退回端上识别
    private static func speechCandidates() -> [(recognizer: SFSpeechRecognizer, onDevice: Bool)] {
        let override = UserDefaults.standard.string(forKey: "textExtractLocale")
        let identifiers = override.map { [$0] } ?? ["zh-CN", "en-US"]
        var result: [(recognizer: SFSpeechRecognizer, onDevice: Bool)] = []

        for identifier in identifiers {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.isAvailable {
                result.append((recognizer, false))
            }
        }
        for identifier in identifiers where !result.contains(where: { $0.recognizer.locale.identifier == identifier }) {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.supportsOnDeviceRecognition {
                result.append((recognizer, true))
            }
        }
        return result
    }

    fileprivate struct Segment {
        var start: Double
        var end: Double
        var text: String
    }

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

    private static func probeBuffer(url: URL, seconds: Double) throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * seconds)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        try file.read(into: buffer, frameCount: frames)
        buffer.frameLength = frames
        return buffer
    }

    /// 片段全被过滤掉时，退回整段格式化文本
    private static func cachedFormatted(_ result: SFSpeechRecognitionResult) -> String? {
        let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

            let once = MacOnceGate()
            let cache = MacSpeechCache()
            let chunkDuration = Double(buffer.frameLength) / buffer.format.sampleRate
            let finish: @Sendable ([Segment]) -> Void = { segments in
                once.perform { continuation.resume(returning: segments) }
            }
            /// 端上识别经常给出空的 final（只带一个空片段），所以要把中途更完整的 partial 留底
            let resolve: @Sendable () -> [Segment] = {
                let cached = cache.best
                return cached.isEmpty ? [] : cached
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    MacTextExtractor.debugLog("recognition error: \(error.localizedDescription)")
                }
                guard let result else { return }
                let raw = result.bestTranscription.segments.map {
                    Segment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                }
                let merged = mergeIntoSentences(raw)
                if !merged.isEmpty {
                    cache.store(merged)
                }
                guard result.isFinal else { return }
                if !merged.isEmpty {
                    finish(merged)
                } else if let plain = cachedFormatted(result) {
                    finish([Segment(start: 0, end: chunkDuration, text: plain)])
                } else {
                    finish(resolve())
                }
            }

            request.append(buffer)
            request.endAudio()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                task.cancel()
                finish(resolve())
            }
        }
    }

    /// 只放行第一次结果的闸门：识别回调与超时回调都会调用 finish。
    final class MacSpeechCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Segment] = []

        fileprivate var best: [Segment] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        fileprivate func store(_ segments: [Segment]) {
            lock.lock()
            stored = segments
            lock.unlock()
        }
    }
}

private final class MacOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func perform(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}

// MARK: - 独立窗口

@MainActor
final class MacTextExtractWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacTextExtractWindowManager()

    private var window: NSWindow?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "一键提取文字"
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 820, height: 620)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let testPath = UserDefaults.standard.string(forKey: "textExtractTestURL")
        let root = MacTextExtractView(
            onClose: { [weak window] in window?.close() },
            debugURL: testPath.map { URL(fileURLWithPath: $0) }
        )
        .tint(MacTheme.accent)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 页面

struct MacTextExtractView: View {
    var onClose: () -> Void
    var debugURL: URL?

    @AppStorage(MacTextExtractPrefs.framesKey) private var includeScreen = true
    @AppStorage(MacTextExtractPrefs.speechKey) private var includeSpeech = true

    @State private var sourceURL: URL?
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimateText = ""
    @State private var sourceDuration: Double = 0
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var phaseText = "准备中…"
    @State private var result: MacTextExtractResult?
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var errorMessage: String?
    @State private var showCancelAlert = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MacTheme.canvas.ignoresSafeArea()

            if let result {
                resultScreen(result)
            } else {
                setupScreen
            }

            if isProcessing {
                processingMask
            }
            if showConfirm {
                confirmOverlay
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.82), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .padding(.bottom, 22)
                }
            }
        }
        .task { await autoStartIfNeeded() }
        .alert("提取失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("停止提取？", isPresented: $showCancelAlert) {
            Button("停止提取", role: .destructive) { cancelProcessing() }
            Button("继续", role: .cancel) {}
        } message: {
            Text("已经识别出来的文字会一并丢弃，视频本身不受影响。")
        }
    }

    // MARK: 选片页

    private var setupScreen: some View {
        VStack(spacing: 0) {
            header(title: "一键提取文字", trailing: nil)

            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    pickCard
                    optionCard
                    noteCard
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.vertical, 16)
            }
        }
    }

    private func header(title: String, trailing: AnyView?) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, MacTheme.pagePadding)
        .padding(.vertical, 12)
        .background(MacTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("把视频里的文字全拿出来")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("画面字幕 + 说话内容，一次转成可以复制的文本")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("逐 0.5 秒抽帧，识别画面里出现的字幕与贴片文字")
                bullet("声音按 30 秒切片转写，分出句子并带上时间码")
                bullet("两种来源可以只取一种，也可以都要")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(MacTheme.accent.opacity(0.6))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pickCard: some View {
        Button {
            Task { @MainActor in pickVideo() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: isPreparing ? "hourglass" : "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(MacTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(isPreparing ? "读取视频中…" : "选择一个视频文件")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("只做识别，不改动原视频，也不会上传")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.28), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparing || isProcessing)
    }

    private var optionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("提取内容", systemImage: "checklist")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("至少保留一项")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            VStack(spacing: 0) {
                optionRow(
                    isOn: Binding(
                        get: { includeScreen },
                        set: { value in
                            if !value && !includeSpeech { return }
                            includeScreen = value
                        }
                    ),
                    title: "画面字幕文字",
                    detail: "识别画面里出现的字幕与贴片文字",
                    symbol: "textformat"
                )

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.leading, 2)

                optionRow(
                    isOn: Binding(
                        get: { includeSpeech },
                        set: { value in
                            if !value && !includeScreen { return }
                            includeSpeech = value
                        }
                    ),
                    title: "声音转文字",
                    detail: "把说话内容转写出来，带时间码",
                    symbol: "waveform"
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("这个设置会记在这台 Mac 上，下次进来还是这次的选择。")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func optionRow(isOn: Binding<Bool>, title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? MacTheme.accent : Color.white.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((isOn.wrappedValue ? MacTheme.accent : Color.white).opacity(0.1))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(MacTheme.accent)
        }
        .padding(.vertical, 7)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("只认画面里看得见的字，视频自带的独立字幕轨道读不到；音乐、多人抢话、方言会降低声音转写的准确度，结果建议再核对一遍。声音转写要重新导出音轨，长片会等得久一些。")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 确认 / 处理

    private var confirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {}

            VStack(spacing: 14) {
                Text("开始提取？")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("时长 \(sourceDuration.timecode) · \(optionSummary)")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))

                VStack(spacing: 2) {
                    Text("预计需要")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text(estimateText.isEmpty ? "几秒" : estimateText)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacTheme.accent)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)

                Text("声音转写要用系统语音识别，第一次会弹权限请求。")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.42))

                HStack(spacing: 10) {
                    Button {
                        showConfirm = false
                        sourceURL = nil
                    } label: {
                        Text("取消")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConfirm = false
                        start()
                    } label: {
                        Text("开始提取")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(MacTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(width: 350)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
        }
    }

    private var optionSummary: String {
        switch (includeScreen, includeSpeech) {
        case (true, true): return "画面 + 声音"
        case (true, false): return "只取画面文字"
        case (false, true): return "只转写声音"
        default: return "画面 + 声音"
        }
    }

    private var processingMask: some View {
        ZStack {
            Color(red: 0.052, green: 0.052, blue: 0.058)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .controlSize(.large)
                    .tint(MacTheme.accent)
                Text("文字提取中 \(Int(progress * 100))%")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(phaseText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.42))

                ProgressView(value: progress)
                    .frame(width: 280)
                    .tint(MacTheme.accent)

                Button("停止提取") { showCancelAlert = true }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }

    // MARK: 结果页

    private func resultScreen(_ result: MacTextExtractResult) -> some View {
        VStack(spacing: 0) {
            header(
                title: "提取结果",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Button("复制全部文字") {
                            copyAll(result)
                        }
                        .buttonStyle(MacTextAccentButtonStyle())
                        .disabled(result.lines.isEmpty)
                        Button("导出 txt…") {
                            exportTxt(result)
                        }
                        .buttonStyle(.bordered)
                        .disabled(result.lines.isEmpty)
                        Button("关闭") { onClose() }
                            .buttonStyle(.bordered)
                    }
                )
            )

            HStack(spacing: 10) {
                infoChip(icon: "text.alignleft", text: "共 \(result.lines.count) 条")
                infoChip(icon: "textformat", text: "画面 \(result.screenCount)")
                infoChip(icon: "waveform", text: "语音 \(result.speechCount)")
                Spacer()
                Button("再提一次") {
                    self.result = nil
                    sourceURL = nil
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, MacTheme.pagePadding)
            .padding(.vertical, 10)

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(MacTheme.accent)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.bottom, 6)
            }

            if result.lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text("没提取到文字")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("这个视频里没有识别到可见的字幕，声音也没转出内容。")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(result.lines) { line in
                            lineRow(line)
                        }
                    }
                    .padding(.horizontal, MacTheme.pagePadding)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(text).font(.caption2)
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func lineRow(_ line: MacExtractedLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(line.timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(line.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(line.source == .screen ? MacTheme.accent : Color(red: 0.45, green: 0.68, blue: 1))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (line.source == .screen ? MacTheme.accent : Color(red: 0.45, green: 0.68, blue: 1)).opacity(0.14),
                        in: Capsule()
                    )
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line.text, forType: .string)
                    showToast("已复制这一条")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("复制这一条")
            }
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 流程

    private func autoStartIfNeeded() async {
        guard let debugURL, result == nil, !isProcessing, !isPreparing, sourceURL == nil else { return }
        if UserDefaults.standard.bool(forKey: "textExtractScreenOnly") {
            includeScreen = true
            includeSpeech = false
        }
        await configure(url: debugURL, autoStart: UserDefaults.standard.bool(forKey: "textExtractSkipConfirm"))
    }

    @MainActor
    private func pickVideo() {
        guard let url = MacAlerts.chooseVideoFile() else { return }
        Task { await configure(url: url, autoStart: false) }
    }

    @MainActor
    private func configure(url: URL, autoStart: Bool) async {
        isPreparing = true
        sourceURL = url
        let asset = AVURLAsset(url: url)
        sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
        estimateText = MacTextExtractor.estimateLabel(
            MacTextExtractor.estimate(
                duration: sourceDuration,
                includeScreen: includeScreen,
                includeSpeech: includeSpeech
            )
        )
        isPreparing = false
        if autoStart {
            start()
        } else {
            showConfirm = true
        }
    }

    private func start() {
        guard let url = sourceURL else { return }
        isProcessing = true
        progress = 0
        phaseText = "准备中…"
        runTask = Task {
            do {
                let res = try await MacTextExtractor.run(
                    url: url,
                    includeScreen: includeScreen,
                    includeSpeech: includeSpeech
                ) { value, phase in
                    Task { @MainActor in
                        progress = value
                        phaseText = phase
                    }
                }
                await MainActor.run {
                    isProcessing = false
                    result = res
                }
            } catch is CancellationError {
                await MainActor.run { isProcessing = false }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelProcessing() {
        runTask?.cancel()
        runTask = nil
        isProcessing = false
        progress = 0
    }

    private func copyAll(_ result: MacTextExtractResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.plainText, forType: .string)
        showToast("已复制 \(result.lines.count) 条文字")
    }

    private func exportTxt(_ result: MacTextExtractResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "文字提取.txt"
        panel.canCreateDirectories = true
        panel.title = "导出文字"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try result.stampedText.write(to: dest, atomically: true, encoding: .utf8)
            showToast("已导出到 \(dest.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toastToken == token { toast = nil }
        }
    }
}

private struct MacTextAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MacTheme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

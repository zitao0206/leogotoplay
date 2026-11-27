import AppKit
import AVFoundation
import CoreImage
import LeogotoPlayCore
import SwiftUI
import Vision

// MARK: - 打码方式

enum MacFaceMaskStyle: String, CaseIterable, Identifiable {
    case pixelate
    case blur
    case solid
    case blurNoise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixelate: return "马赛克"
        case .blur: return "高斯模糊"
        case .solid: return "纯色 / 黑块"
        case .blurNoise: return "模糊 + 轻噪点"
        }
    }

    var detail: String {
        switch self {
        case .pixelate:
            return "块大小跟着脸宽走（约脸宽 1/12），大脸不会糊成一片，小脸也不会等于没打。"
        case .blur:
            return "半径同样跟脸宽走，观感更像新闻里的处理方式。"
        case .solid:
            return "最保险，但不好看，适合正式场合。"
        case .blurNoise:
            return "模糊再叠一层轻噪点，抗「人脸还原」工具的效果稍好一点。"
        }
    }

    var symbol: String {
        switch self {
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop.halffull"
        case .solid: return "rectangle.fill"
        case .blurNoise: return "circle.dotted"
        }
    }
}

enum MacFaceMaskPrefs {
    static let styleKey = "face.mask.style"
}

struct MacFaceMaskResult {
    let url: URL
    let duration: Double
    let faceCount: Int
    let framesWithFaces: Int
    let style: MacFaceMaskStyle
    let sourceTitle: String
}

enum MacFaceMaskError: LocalizedError {
    case noVideoTrack
    case noFaceFound
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频画面"
        case .noFaceFound: return "整段视频没有检测到人脸"
        case .readerFailed(let reason): return "读取视频失败：\(reason)"
        case .writerFailed(let reason): return "写出视频失败：\(reason)"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 逐帧检测 + 重编码

enum MacFaceMasker {

    static func estimate(duration: Double, style: MacFaceMaskStyle) -> Double {
        // macOS 端实测比 iOS 快约 3 倍（Apple 芯片上 20 秒片子约 5 秒跑完），估时按 0.30 每秒给
        let base = 1.0 + duration * 0.30
        return style == .blurNoise ? base + duration * 0.05 : base
    }

    static func estimateLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "约 \(Int(seconds.rounded(.up))) 秒" }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if rest == 0 { return "约 \(minutes) 分钟" }
        return "约 \(minutes) 分 \(rest) 秒"
    }

    static func run(
        url: URL,
        style: MacFaceMaskStyle,
        onProgress: @escaping (Double) -> Void
    ) async throws -> MacFaceMaskResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            throw MacFaceMaskError.noVideoTrack
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let orientedSize = transform.maskIsQuarterTurn
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let nominalFPS = max((try? await videoTrack.load(.nominalFrameRate)) ?? 0, 1)
        let totalFrames = max(Int((duration * Double(nominalFPS)).rounded()), 1)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MacFaceMaskError.readerFailed("无法读取视频轨道")
        }
        reader.add(videoOutput)

        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-mask-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = Int(orientedSize.width.rounded())
        let height = Int(orientedSize.height.rounded())
        let bitrate = max(Int(Double(width * height) * Double(nominalFPS) * 0.10), 2_000_000)
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
            throw MacFaceMaskError.writerFailed("无法写入视频轨道")
        }
        writer.add(videoInput)

        guard writer.startWriting(), reader.startReading() else {
            throw MacFaceMaskError.writerFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "无法开始"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let detScale = min(1, 720 / max(orientedSize.width, orientedSize.height))
        var tracker = MaskFaceTracker()
        var frameIndex = 0
        var framesWithFaces = 0
        let detector = MaskFaceDetector()
        let stride = 2

        while let sample = videoOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw MacFaceMaskError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)

            autoreleasepool {
                let base = uprightImage(pixelBuffer: pixelBuffer, transform: transform, size: orientedSize)

                if frameIndex % stride == 0 {
                    let small = base.maskScaled(by: detScale)
                    let observations = detector.detect(image: small)
                    tracker.update(observations: observations, frame: frameIndex, maxAge: stride * 2 + 4)
                }

                let rects = tracker.rects(at: frameIndex, viewSize: orientedSize, maxAge: stride * 2 + 4)
                if !rects.isEmpty { framesWithFaces += 1 }

                let masked = applyMasks(to: base, rects: rects, size: orientedSize, style: style, context: context)

                if let pool = adaptor.pixelBufferPool {
                    var target: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
                    if let target {
                        context.render(
                            masked,
                            to: target,
                            bounds: CGRect(origin: .zero, size: orientedSize),
                            colorSpace: CGColorSpaceCreateDeviceRGB()
                        )
                        while !videoInput.isReadyForMoreMediaData {
                            usleep(2000)
                        }
                        adaptor.append(target, withPresentationTime: presentation)
                    }
                }
            }

            frameIndex += 1
            if frameIndex % 5 == 0 {
                let value = min(1, Double(frameIndex) / Double(max(totalFrames, 1)))
                onProgress(min(value, 0.95))
            }
        }

        onProgress(0.96)
        videoInput.markAsFinished()

        await writer.finishWriting()
        onProgress(1)

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw MacFaceMaskError.writerFailed(writer.error?.localizedDescription ?? "写入未完成")
        }
        if tracker.totalFaces == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            throw MacFaceMaskError.noFaceFound
        }

        // 音频单独封一层：AVAssetWriter 的音频透传输入在 mp4 上 canAdd 会返回 false
        var finalURL = outputURL
        if audioTrack != nil {
            finalURL = try await muxAudio(from: asset, video: outputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        return MacFaceMaskResult(
            url: finalURL,
            duration: duration,
            faceCount: tracker.totalFaces,
            framesWithFaces: framesWithFaces,
            style: style,
            sourceTitle: url.deletingPathExtension().lastPathComponent
        )
    }

    /// 把无声视频和原音轨用 passthrough 封到一起（不重编码）。
    static func muxAudio(from asset: AVURLAsset, video: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let sourceVideo = (try? await videoAsset.loadTracks(withMediaType: .video))?.first,
              let compVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw MacFaceMaskError.writerFailed("无法封装视频轨")
        }
        let videoDuration = (try? await videoAsset.load(.duration)) ?? .zero
        let videoRange = (try? await sourceVideo.load(.timeRange))
            ?? CMTimeRange(start: .zero, duration: videoDuration)
        try compVideo.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        if let transform = try? await sourceVideo.load(.preferredTransform) {
            compVideo.preferredTransform = transform
        }

        if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first,
           let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
           ),
           let audioRange = try? await audioTrack.load(.timeRange) {
            let audioLength = CMTimeMinimum(audioRange.duration, videoRange.duration)
            if audioLength > .zero {
                try? compAudio.insertTimeRange(
                    CMTimeRange(start: audioRange.start, duration: audioLength),
                    of: audioTrack,
                    at: .zero
                )
            }
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MacFaceMaskError.writerFailed("无法创建封装会话")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-mask-mux-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        let types = session.supportedFileTypes
        session.outputFileType = types.contains(.mp4) ? .mp4 : (types.first ?? .mov)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw MacFaceMaskError.writerFailed(session.error?.localizedDescription ?? "音频封装失败")
        }
        return url
    }

    // MARK: 画面

    static func uprightImage(
        pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform,
        size: CGSize
    ) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            let extent = image.extent
            if extent.origin != .zero {
                image = image.transformed(
                    by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
                )
            }
        }
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func applyMasks(
        to base: CIImage,
        rects: [CGRect],
        size: CGSize,
        style: MacFaceMaskStyle,
        context: CIContext
    ) -> CIImage {
        guard !rects.isEmpty else { return base }
        var result = base
        for rect in rects {
            let patch: CIImage
            switch style {
            case .pixelate:
                let scale = max(8, rect.width / 12)
                patch = base.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)
                    ])
                    .cropped(to: rect)
            case .blur:
                patch = base.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: max(12, rect.width * 0.09)
                    ])
                    .cropped(to: rect)
            case .solid:
                patch = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.06)).cropped(to: rect)
            case .blurNoise:
                let blurred = base.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: max(10, rect.width * 0.075)
                    ])
                    .cropped(to: rect)
                let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage.empty()
                let tinted = noise
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.35, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.35, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.35, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)
                    ])
                    .cropped(to: rect)
                patch = tinted.composited(over: blurred)
            }
            result = patch.composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }
}

// MARK: - 检测

final class MaskFaceDetector {
    private enum Backend {
        case visionGPU
        case coreImage
        case dead
    }

    private var backend: Backend = .visionGPU
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    private let sequenceHandler = VNSequenceRequestHandler()

    private lazy var ciDetector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    /// 返回 (稳定 id, 归一化框)，框以左下角为原点，与 Vision 一致。
    func detect(image: CIImage) -> [(UUID?, CGRect)] {
        while true {
            switch backend {
            case .visionGPU:
                if let faces = run(on: image) { return faces }
                backend = .coreImage
            case .coreImage:
                return detectWithCoreImage(image)
            case .dead:
                return []
            }
        }
    }

    private func run(on image: CIImage) -> [(UUID?, CGRect)]? {
        do {
            try sequenceHandler.perform([request], on: image, orientation: .up)
            let faces = request.results ?? []
            return faces.map { ($0.uuid, $0.boundingBox) }
        } catch {
            return nil
        }
    }

    private func detectWithCoreImage(_ image: CIImage) -> [(UUID?, CGRect)] {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, let ciDetector else {
            backend = .dead
            return []
        }
        let features = ciDetector.features(in: image)
        return features.compactMap { feature in
            let box = feature.bounds
            guard box.width > 6, box.height > 6 else { return nil }
            let local = CGRect(
                x: box.minX - extent.minX,
                y: box.minY - extent.minY,
                width: box.width,
                height: box.height
            )
            return (nil, CGRect(
                x: local.minX / extent.width,
                y: local.minY / extent.height,
                width: local.width / extent.width,
                height: local.height / extent.height
            ))
        }
    }
}

// MARK: - 轨迹

private struct MaskTrackedFace {
    var rect: CGRect
    var lastFrame: Int
}

private struct MaskFaceTracker {
    private var tracks: [UUID: MaskTrackedFace] = [:]
    private(set) var totalFaces = 0

    mutating func update(observations: [(UUID?, CGRect)], frame: Int, maxAge: Int) {
        var claimed = Set<UUID>()

        for (uuid, rect) in observations {
            if let uuid, tracks[uuid] != nil, !claimed.contains(uuid) {
                claimed.insert(uuid)
                tracks[uuid] = MaskTrackedFace(
                    rect: blend(tracks[uuid]!.rect, rect, keep: 0.7),
                    lastFrame: frame
                )
                continue
            }
            if let match = nearest(to: rect, excluding: claimed) {
                claimed.insert(match)
                tracks[match] = MaskTrackedFace(
                    rect: blend(tracks[match]!.rect, rect, keep: 0.7),
                    lastFrame: frame
                )
            } else {
                let id = UUID()
                tracks[id] = MaskTrackedFace(rect: rect, lastFrame: frame)
                totalFaces += 1
                claimed.insert(id)
            }
        }

        tracks = tracks.filter { claimed.contains($0.key) || frame - $0.value.lastFrame < maxAge }
    }

    func rects(at frame: Int, viewSize: CGSize, maxAge: Int) -> [CGRect] {
        var result: [CGRect] = []
        for tracked in tracks.values {
            guard frame - tracked.lastFrame < maxAge else { continue }
            let normalized = tracked.rect
            let pixel = CGRect(
                x: normalized.minX * viewSize.width,
                y: normalized.minY * viewSize.height,
                width: normalized.width * viewSize.width,
                height: normalized.height * viewSize.height
            )
            let rect = pixel.maskExpanded(by: 0.28).maskClamped(in: CGRect(origin: .zero, size: viewSize))
            guard !rect.isEmpty else { continue }
            if result.contains(where: { $0.maskOverlapRatio(with: rect) > 0.6 }) { continue }
            result.append(rect)
        }
        return result
    }

    private func nearest(to rect: CGRect, excluding claimed: Set<UUID>) -> UUID? {
        var best: (UUID, CGFloat)?
        for (id, tracked) in tracks where !claimed.contains(id) {
            let limit = max(tracked.rect.width, tracked.rect.height) * 0.6
            let dx = tracked.rect.midX - rect.midX
            let dy = tracked.rect.midY - rect.midY
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < limit else { continue }
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best?.0
    }

    private func blend(_ old: CGRect, _ new: CGRect, keep: CGFloat) -> CGRect {
        let rest = 1 - keep
        return CGRect(
            x: old.minX * keep + new.minX * rest,
            y: old.minY * keep + new.minY * rest,
            width: old.width * keep + new.width * rest,
            height: old.height * keep + new.height * rest
        )
    }
}

// MARK: - 小工具

private extension CIImage {
    func maskScaled(by scale: CGFloat) -> CIImage {
        guard scale != 1 else { return self }
        return transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(
                origin: .zero,
                size: extent.size.applying(CGAffineTransform(scaleX: scale, y: scale))
            ))
    }
}

private extension CGRect {
    var maskArea: CGFloat { width * height }

    func maskOverlapRatio(with other: CGRect) -> CGFloat {
        guard intersects(other) else { return 0 }
        let shared = intersection(other)
        return shared.width * shared.height / max(maskArea, 1)
    }

    func maskExpanded(by ratio: CGFloat) -> CGRect {
        insetBy(dx: -size.width * ratio, dy: -size.height * ratio)
    }

    func maskClamped(in bounds: CGRect) -> CGRect {
        let rect = intersection(bounds)
        return rect.isNull || rect.isEmpty ? .zero : rect
    }
}

private extension CGAffineTransform {
    var maskIsQuarterTurn: Bool {
        let angle = atan2(b, a)
        let degrees = Int((angle * 180 / .pi).rounded())
        return abs(degrees) == 90 || abs(degrees) == 270
    }
}

// MARK: - 独立窗口

@MainActor
final class MacFaceMaskWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacFaceMaskWindowManager()

    private var window: NSWindow?

    func open(library: LibraryStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "一键人脸打码"
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 860, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let testPath = UserDefaults.standard.string(forKey: "faceMaskTestURL")
        let root = MacFaceMaskView(
            library: library,
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

struct MacFaceMaskView: View {
    @ObservedObject var library: LibraryStore
    var onClose: () -> Void
    var debugURL: URL?

    @AppStorage(MacFaceMaskPrefs.styleKey) private var styleRaw = MacFaceMaskStyle.pixelate.rawValue

    @State private var sourceURL: URL?
    @State private var sourceDuration: Double = 0
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimateText = ""
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var phaseText = "正在定位人脸"
    @State private var result: MacFaceMaskResult?
    @State private var showCancelAlert = false
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isExporting = false
    @State private var runTask: Task<Void, Never>?

    private var style: MacFaceMaskStyle {
        MacFaceMaskStyle(rawValue: styleRaw) ?? .pixelate
    }

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
        .alert("打码失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("停止打码？", isPresented: $showCancelAlert) {
            Button("停止打码", role: .destructive) { cancelProcessing() }
            Button("继续", role: .cancel) {}
        } message: {
            Text("这一段处理进度会丢弃，原视频不受影响。")
        }
    }

    // MARK: 选片页

    private var setupScreen: some View {
        VStack(spacing: 0) {
            header(title: "一键人脸打码", trailing: nil)

            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    pickCard
                    styleCard
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
                Image(systemName: "face.dashed")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动把画面里的人脸遮住")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("逐帧找人脸，整段重新编码，出一个打码新片")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("逐帧检测人脸位置，整段视频里的人都会被遮住")
                bullet("四种遮挡方式，块大小和模糊半径都跟着脸宽走")
                bullet("全程在本机处理，原视频不动，也不会上传")
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
                Text("选本地视频，处理好后生成一个打了码的新片")
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

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("打码方式", systemImage: "paintbrush")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("会记住上次的选择")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            VStack(spacing: 0) {
                ForEach(MacFaceMaskStyle.allCases) { option in
                    Button {
                        styleRaw = option.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(option == style ? MacTheme.accent : Color.white.opacity(0.45))
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill((option == style ? MacTheme.accent : Color.white).opacity(0.1))
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(option.detail)
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.5))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: option == style ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(option == style ? MacTheme.accent : Color.white.opacity(0.25))
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if option != MacFaceMaskStyle.allCases.last {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.leading, 42)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("打码要重新编码整段视频，画质会有轻微损失。侧脸、被手挡住的脸、画面里很小的人脸可能漏检，重要素材建议先看一遍结果。处理期间窗口不要关，关了会中断。")
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
                Text("开始打码？")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("时长 \(sourceDuration.timecode) · \(style.title)")
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

                Text("要重新编码整段视频，越长的片子越久。")
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
                        Text("开始打码")
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

    private var processingMask: some View {
        ZStack {
            Color(red: 0.052, green: 0.052, blue: 0.058)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .controlSize(.large)
                    .tint(MacTheme.accent)
                Text("人脸打码中 \(Int(progress * 100))%")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(phaseText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.42))

                ProgressView(value: progress)
                    .frame(width: 280)
                    .tint(MacTheme.accent)

                Button("停止打码") { showCancelAlert = true }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }

    // MARK: 结果页

    private func resultScreen(_ result: MacFaceMaskResult) -> some View {
        VStack(spacing: 0) {
            header(
                title: "打码完成",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Button(isSaving ? "保存中…" : "存入素材库") {
                            saveToLibrary(result)
                        }
                        .buttonStyle(MacMaskAccentButtonStyle())
                        .disabled(isSaving || isExporting)
                        Button(isExporting ? "导出中…" : "另存为…") {
                            exportCopy(result)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving || isExporting)
                        Button("关闭") { closeCleanup(result) }
                            .buttonStyle(.bordered)
                    }
                )
            )

            HStack(spacing: 10) {
                infoChip(icon: "person.crop.circle", text: "检测到 \(result.faceCount) 个人")
                infoChip(icon: "clock", text: "时长 \(result.duration.timecode)")
                infoChip(icon: "paintbrush", text: result.style.title)
                Spacer()
                Button("再打一次") {
                    self.result = nil
                    sourceURL = nil
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, MacTheme.pagePadding)
            .padding(.vertical, 10)

            MacMaskPreview(url: result.url)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.bottom, 16)
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

    // MARK: 流程

    private func autoStartIfNeeded() async {
        guard let debugURL, result == nil, !isProcessing, !isPreparing, sourceURL == nil else { return }
        if let styleRawDebug = UserDefaults.standard.string(forKey: "faceMaskStyle"),
           MacFaceMaskStyle(rawValue: styleRawDebug) != nil {
            styleRaw = styleRawDebug
        }
        await configure(url: debugURL, autoStart: UserDefaults.standard.bool(forKey: "faceMaskSkipConfirm"))
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
        estimateText = MacFaceMasker.estimateLabel(
            MacFaceMasker.estimate(duration: sourceDuration, style: style)
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
        phaseText = "正在定位并遮挡人脸"
        runTask = Task {
            do {
                let res = try await MacFaceMasker.run(url: url, style: style) { value in
                    Task { @MainActor in
                        progress = value
                        phaseText = value > 0.55 ? "正在重新编码画面" : "正在定位并遮挡人脸"
                    }
                }
                await MainActor.run {
                    isProcessing = false
                    result = res
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    if let maskError = error as? MacFaceMaskError, case .cancelled = maskError { return }
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

    private func saveToLibrary(_ result: MacFaceMaskResult) {
        isSaving = true
        let title = "\(result.sourceTitle)-打码"
        Task { @MainActor in
            do {
                try await library.importExport(fileURL: result.url, title: title)
                isSaving = false
                showToast("已存入素材库")
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportCopy(_ result: MacFaceMaskResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(result.sourceTitle)-打码.mp4"
        panel.canCreateDirectories = true
        panel.title = "导出打码视频"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        isExporting = true
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: result.url, to: dest)
            isExporting = false
            showToast("已导出到 \(dest.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            isExporting = false
            errorMessage = error.localizedDescription
        }
    }

    private func closeCleanup(_ result: MacFaceMaskResult) {
        try? FileManager.default.removeItem(at: result.url)
        onClose()
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toastToken == token { toast = nil }
        }
    }
}

/// 结果页主色按钮
private struct MacMaskAccentButtonStyle: ButtonStyle {
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

// MARK: - 结果预览（播放 + 可拖动进度条）

private struct MacMaskPreview: View {
    let url: URL

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 8) {
            MacPlayerSurface(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(MacTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)

                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { min(time, max(duration, 0.01)) },
                            set: { newValue in
                                time = newValue
                                seek(to: newValue)
                            }
                        ),
                        in: 0...max(duration, 0.01),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if editing {
                                player.pause()
                                isPlaying = false
                            }
                        }
                    )
                    .tint(MacTheme.accent)

                    HStack {
                        Text(time.timecode)
                        Spacer()
                        Text(duration.timecode)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
        .padding(10)
        .background(MacTheme.surface)
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let asset = AVURLAsset(url: url)
            Task {
                let seconds = (try? await asset.load(.duration).seconds) ?? 0
                await MainActor.run { duration = seconds }
            }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { current in
                guard !isScrubbing else { return }
                time = current.seconds
                if let item = player.currentItem, item.duration.seconds > 0,
                   current.seconds >= item.duration.seconds - 0.05 {
                    isPlaying = false
                }
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
    }

    private func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.1 {
                seek(to: 0)
                time = 0
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

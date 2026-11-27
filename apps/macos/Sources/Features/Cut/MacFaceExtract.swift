import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import Vision

// MARK: - 数据

/// 提到的一张脸（对应 iOS 的 ExtractedFace，图片换成 NSImage）
struct MacExtractedFace: Identifiable {
    let id = UUID()
    let image: NSImage
    /// 在视频里第一次出现的时间（秒）
    let time: Double
    /// Vision 的画面质量分，用来在同一张脸的多帧里挑最好的
    let quality: Float
}

struct MacFaceExtractResult {
    let faces: [MacExtractedFace]
    let duration: Double
}

enum MacFaceExtractError: LocalizedError {
    case noVideoTrack
    case noFaceFound
    case readerFailed(String)
    case saveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return T("这个文件里没有视频画面")
        case .noFaceFound: return T("整段视频没有检测到清晰的人脸")
        case .readerFailed(let reason): return T("读取视频失败：{1}", reason)
        case .saveFailed(let reason): return T("保存失败：{1}", reason)
        case .cancelled: return T("已取消")
        }
    }
}

enum MacFaceExtractPrefs {
    private static let intervalKey = "face.extract.interval"

    static var frameInterval: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            guard stored > 0 else { return 1 }
            return min(max(stored, 1), 10)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), 10), forKey: intervalKey)
        }
    }
}

// MARK: - 提取器（与 iOS 同一套算法，输出改成 NSImage、保存改成写文件夹）

enum MacFaceExtractor {

    static let frameIntervalRange: ClosedRange<Double> = 1...10
    static let defaultFrameInterval: Double = 1
    static let maxFaces = 80
    private static let minFacePixels: CGFloat = 48

    struct Estimate {
        let duration: Double
        let frames: Int
        let seconds: Double
        let interval: Double

        var summary: String {
            let intervalText = T("每 {1} 秒 1 帧", Int(interval))
            return duration > 0
                ? T("视频 {1} · {2} · {3} 帧", duration.timecode, intervalText, frames)
                : T("{1} · {2} 帧", intervalText, frames)
        }

        var durationLabel: String { MacFaceExtractor.estimateLabel(seconds) }
    }

    private static let fallbackSecondsPerFrame: Double = 0.06

    static func estimate(url: URL, frameInterval: Double = defaultFrameInterval) async -> Estimate {
        let interval = clamp(frameInterval, 1, 10)
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let frames = max(1, Int((duration / interval).rounded(.up)))
        let perFrame = (await probeSecondsPerFrame(url: url)) ?? fallbackSecondsPerFrame
        let seconds = clamp(1.0 + Double(frames) * perFrame * 1.25, 2, 900)
        return Estimate(duration: duration, frames: frames, seconds: seconds, interval: interval)
    }

    static func estimateLabel(_ seconds: Double) -> String {
        if seconds < 60 { return T("约 {1} 秒", Int(seconds.rounded(.up))) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if rest == 0 { return T("约 {1} 分钟", minutes) }
        return T("约 {1} 分 {2} 秒", minutes, rest)
    }

    private static func probeSecondsPerFrame(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let geometry = await videoGeometry(of: asset) else { return nil }
        let track = geometry.track
        let transform = geometry.transform
        let size = geometry.size
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let start = clamp(duration / 2, 0, max(duration - 0.3, 0))
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        let detector = Detector()
        let scale = min(1, 720 / max(size.width, size.height))
        var timings: [Double] = []

        while timings.count < 3, let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = orientedImage(pixelBuffer, transform: transform, size: size)
            let detectionImage = scale < 1
                ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : image
            let began = CACurrentMediaTime()
            _ = detector.detect(in: detectionImage)
            timings.append(CACurrentMediaTime() - began)
        }

        guard let last = timings.last, last > 0 else { return nil }
        let settled = timings.dropFirst()
        let perFrame = settled.isEmpty
            ? last / 2
            : settled.reduce(0, +) / Double(settled.count)
        return clamp(perFrame, 0.005, 2)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    private struct VideoGeometry {
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let size: CGSize
    }

    private static func videoGeometry(of asset: AVURLAsset) async -> VideoGeometry? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        guard naturalSize.width > 1, naturalSize.height > 1 else { return nil }
        let size = transform.isQuarterTurn
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        guard size.width > 1, size.height > 1 else { return nil }
        return VideoGeometry(track: track, transform: transform, size: size)
    }

    static func run(
        url: URL,
        frameInterval: Double = defaultFrameInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> MacFaceExtractResult {
        let asset = AVURLAsset(url: url)
        guard let geometry = await videoGeometry(of: asset) else {
            throw MacFaceExtractError.noVideoTrack
        }
        let videoTrack = geometry.track
        let transform = geometry.transform
        let orientedSize = geometry.size
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MacFaceExtractError.readerFailed(T("无法读取视频轨道"))
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MacFaceExtractError.readerFailed(reader.error?.localizedDescription ?? T("无法开始读取"))
        }

        let interval = clamp(frameInterval, 1, 10)
        let trackWindow = max(1.6, interval * 1.5)
        let context = CIContext(options: [.cacheIntermediates: false])
        let detector = Detector()
        let detScale = min(1, 720 / max(orientedSize.width, orientedSize.height))

        var faces: [MacExtractedFace] = []
        var tracks: [Track] = []
        var lastSample: Double = -1

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw MacFaceExtractError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if lastSample >= 0, pts - lastSample < interval - 0.001 { continue }
            lastSample = pts

            autoreleasepool {
                let image = orientedImage(pixelBuffer, transform: transform, size: orientedSize)
                let detectionImage = detScale < 1
                    ? image.transformed(by: CGAffineTransform(scaleX: detScale, y: detScale))
                    : image

                for (norm, quality) in detector.detect(in: detectionImage) {
                    let faceRect = CGRect(
                        x: norm.minX * orientedSize.width,
                        y: norm.minY * orientedSize.height,
                        width: norm.width * orientedSize.width,
                        height: norm.height * orientedSize.height
                    )
                    guard min(faceRect.width, faceRect.height) >= minFacePixels else { continue }
                    let crop = cropRect(around: faceRect, in: orientedSize)
                    guard let cgImage = context.createCGImage(image.cropped(to: crop), from: crop) else { continue }
                    let faceImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

                    if let index = tracks.firstIndex(where: {
                        $0.lastTime > pts - trackWindow
                            && (overlap($0.rect, crop) > 0.35 || isSameSpot($0.rect, crop))
                    }) {
                        tracks[index].rect = crop
                        tracks[index].lastTime = pts
                        let faceIndex = tracks[index].faceIndex
                        if quality > faces[faceIndex].quality + 0.06 {
                            faces[faceIndex] = MacExtractedFace(
                                image: faceImage,
                                time: faces[faceIndex].time,
                                quality: quality
                            )
                        }
                    } else {
                        faces.append(MacExtractedFace(image: faceImage, time: pts, quality: quality))
                        tracks.append(Track(rect: crop, lastTime: pts, faceIndex: faces.count - 1))
                    }
                }
            }

            onProgress(min(max(pts / max(duration, 0.01), 0), 0.99))
        }

        if reader.status == .failed {
            throw MacFaceExtractError.readerFailed(reader.error?.localizedDescription ?? T("读取中断"))
        }
        guard !faces.isEmpty else { throw MacFaceExtractError.noFaceFound }

        let sorted = faces.sorted { $0.time < $1.time }
        let limited = sorted.count > maxFaces
            ? sorted.sorted { $0.quality > $1.quality }.prefix(maxFaces).sorted { $0.time < $1.time }
            : sorted
        onProgress(1)
        return MacFaceExtractResult(faces: Array(limited), duration: duration)
    }

    /// 把每张脸按 JPG 写进指定目录，返回写入张数。macOS 没有相册可写，改成本地导出。
    static func write(faces: [MacExtractedFace], to directory: URL) throws -> Int {
        var written = 0
        for (index, face) in faces.enumerated() {
            guard let tiff = face.image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { continue }
            let name = String(format: "face_%02d_%@.jpg", index + 1, face.time.timecode.replacingOccurrences(of: ":", with: "-"))
            do {
                try data.write(to: directory.appendingPathComponent(name))
                written += 1
            } catch {
                throw MacFaceExtractError.saveFailed(error.localizedDescription)
            }
        }
        guard written > 0 else { throw MacFaceExtractError.saveFailed(T("没有可保存的图片")) }
        return written
    }

    // MARK: - 内部

    private struct Track {
        var rect: CGRect
        var lastTime: Double
        var faceIndex: Int
    }

    private static func orientedImage(
        _ pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform,
        size: CGSize
    ) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            let extent = image.extent
            if extent.origin != .zero {
                image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            }
        }
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func cropRect(around face: CGRect, in size: CGSize) -> CGRect {
        let height = min(size.height, max(face.height * 2, 120))
        let width = min(size.width, height * 0.75)
        let centerY = face.midY + face.height * 0.15
        var rect = CGRect(x: face.midX - width / 2, y: centerY - height / 2, width: width, height: height)
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > size.width { rect.origin.x = size.width - rect.width }
        if rect.maxY > size.height { rect.origin.y = size.height - rect.height }
        return rect
    }

    /// 人物小幅移动时 IoU 会掉下来，用中心距离 + 尺寸比例兜底，避免同一张脸被拆成好几条。
    private static func isSameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx = abs(a.midX - b.midX) / max(a.width, b.width)
        let dy = abs(a.midY - b.midY) / max(a.height, b.height)
        let ratio = a.height / max(b.height, 1)
        return dx < 0.32 && dy < 0.32 && ratio > 0.65 && ratio < 1.55
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        guard union > 0 else { return 0 }
        return inter.width * inter.height / union
    }

    // MARK: - 人脸检测（Vision 优先，失败逐级降级到 Core Image）

    final class Detector {
        enum Backend {
            case qualityGPU, qualityCPU, rectGPU, rectCPU, coreImage, dead
        }

        var backend: Backend = .qualityGPU
        private let handler = VNSequenceRequestHandler()

        private let qualityGPU: VNDetectFaceCaptureQualityRequest = {
            let request = VNDetectFaceCaptureQualityRequest()
            request.revision = VNDetectFaceCaptureQualityRequestRevision1
            return request
        }()

        private let qualityCPU: VNDetectFaceCaptureQualityRequest = {
            let request = VNDetectFaceCaptureQualityRequest()
            request.revision = VNDetectFaceCaptureQualityRequestRevision1
            return request
        }()

        private let rectGPU: VNDetectFaceRectanglesRequest = {
            let request = VNDetectFaceRectanglesRequest()
            request.revision = VNDetectFaceRectanglesRequestRevision3
            return request
        }()

        private let rectCPU: VNDetectFaceRectanglesRequest = {
            let request = VNDetectFaceRectanglesRequest()
            request.revision = VNDetectFaceRectanglesRequestRevision3
            return request
        }()

        private lazy var ciDetector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )

        func detect(in image: CIImage) -> [(CGRect, Float)] {
            while true {
                switch backend {
                case .qualityGPU:
                    if let faces = run(qualityGPU, on: image) { return faces }
                    backend = .qualityCPU
                case .qualityCPU:
                    if let faces = run(qualityCPU, on: image) { return faces }
                    backend = .rectGPU
                case .rectGPU:
                    if let faces = run(rectGPU, on: image) { return faces }
                    backend = .rectCPU
                case .rectCPU:
                    if let faces = run(rectCPU, on: image) { return faces }
                    backend = .coreImage
                case .coreImage:
                    return detectWithCoreImage(image)
                case .dead:
                    return []
                }
            }
        }

        private func run(_ request: VNRequest, on image: CIImage) -> [(CGRect, Float)]? {
            do {
                try handler.perform([request], on: image, orientation: .up)
                guard let observations = request.results as? [VNFaceObservation] else { return [] }
                return observations.map { ($0.boundingBox, $0.faceCaptureQuality ?? 0.5) }
            } catch {
                return nil
            }
        }

        private func detectWithCoreImage(_ image: CIImage) -> [(CGRect, Float)] {
            let extent = image.extent
            guard extent.width > 1, extent.height > 1, let ciDetector else {
                backend = .dead
                return []
            }
            let features = ciDetector.features(in: image)
            guard !features.isEmpty else { return [] }
            return features.compactMap { feature in
                let box = feature.bounds
                guard box.width > 8, box.height > 8 else { return nil }
                let norm = CGRect(
                    x: (box.minX - extent.minX) / extent.width,
                    y: (box.minY - extent.minY) / extent.height,
                    width: box.width / extent.width,
                    height: box.height / extent.height
                )
                return (norm, Float(0.5))
            }
        }
    }
}

private extension CGAffineTransform {
    var isQuarterTurn: Bool {
        let angle = atan2(b, a)
        let degrees = Int((angle * 180 / .pi).rounded())
        return abs(degrees) == 90 || abs(degrees) == 270
    }
}

// MARK: - 独立窗口

@MainActor
final class MacFaceExtractWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacFaceExtractWindowManager()

    private var window: NSWindow?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = T("一键提取人脸")
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 860, height: 620)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let testPath = UserDefaults.standard.string(forKey: "faceExtractTestURL")
        let root = MacFaceExtractView(
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

struct MacFaceExtractView: View {
    var onClose: () -> Void
    /// Debug 钩子：启动参数 `-faceExtractTestURL /path/x.mp4` 时直接跑这一条，省去驱动 NSOpenPanel。
    var debugURL: URL?

    @State private var fileURL: URL?
    @State private var isPreparing = false
    @State private var estimate: MacFaceExtractor.Estimate?
    @State private var showConfirm = false
    @State private var frameInterval: Double = MacFaceExtractPrefs.frameInterval
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var result: MacFaceExtractResult?
    @State private var previewFace: MacExtractedFace?
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var errorMessage: String?
    @State private var isExporting = false
    @State private var exportedCount: Int?
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
            if let previewFace {
                previewOverlay(previewFace)
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
        .alert(T("提取失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(T("知道了"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await autoStartIfNeeded() }
        .alert(T("停止提取？"), isPresented: $showCancelAlert) {
            Button(T("停止提取"), role: .destructive) { cancelProcessing() }
            Button(T("继续"), role: .cancel) {}
        } message: {
            Text(T("已经扫过的部分会丢弃，原视频不受影响。"))
        }
    }

    // MARK: 选片页

    private var setupScreen: some View {
        VStack(spacing: 0) {
            header(title: T("一键提取人脸"), trailing: nil)

            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    intervalCard
                    pickCard
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
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("把视频里的每张脸单独挑出来"))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(T("扫完一段视频，按人分好，裁成可以直接用的图片"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet(T("按设定的取帧间隔扫完整段视频，同一张脸只留最清楚的一张"))
                bullet(T("按 3:4 竖图裁切，自带一点额头和头发，可以直接当头像用"))
                bullet(T("全程在本机处理，原视频不动，也不会上传"))
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

    private var intervalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(T("取帧间隔"), systemImage: "speedometer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text(T("每 {1} 秒 1 帧", Int(frameInterval)))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MacTheme.accent)
                    .monospacedDigit()
            }

            Slider(value: $frameInterval, in: 1...10, step: 1)
                .tint(MacTheme.accent)
                .disabled(isPreparing || isProcessing)
                .onChange(of: frameInterval) { value in
                    let rounded = min(max(value.rounded(), 1), 10)
                    frameInterval = rounded
                    MacFaceExtractPrefs.frameInterval = rounded
                }

            HStack {
                Text(T("1 秒（最细）"))
                Spacer()
                Text(T("10 秒（最省）"))
            }
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.4))

            Text(T("1 秒取 1 帧最不容易漏掉人脸，耗时也最长；往后每加 1 秒，抽检帧数和耗时约少一成，一闪而过的脸就更容易漏。"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                Text(isPreparing ? T("读取视频中…") : T("选择一个视频文件"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(T("选本地视频，处理好后把每张脸列出来"))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.28), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparing || isProcessing)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(T("说明"), systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(T("侧脸、被手挡住的脸、画面里很小的路人脸可能抓不到。视频里出现的人越多、换人越频繁，提取出来的张数越多，最多保留 80 张；同一张脸只留质量最好的一帧。原视频不会被修改。提取完可以导出到一个文件夹里。"))
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
                Text(T("开始提取人脸？"))
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(estimate?.summary ?? T("正在评估耗时…"))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))

                VStack(spacing: 2) {
                    Text(T("按本机速度预计需要"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text(estimate?.durationLabel ?? T("几秒"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacTheme.accent)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button {
                        showConfirm = false
                        fileURL = nil
                    } label: {
                        Text(T("取消"))
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
                        Text(T("开始提取"))
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
            .frame(width: 340)
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
            VStack(spacing: 26) {
                ProgressView()
                    .controlSize(.large)
                    .tint(MacTheme.accent)
                Text(T("人脸提取中 {1}%", Int(progress * 100)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(T("正在逐帧扫描人脸"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.42))

                ProgressView(value: progress)
                    .frame(width: 280)
                    .tint(MacTheme.accent)

                Button(T("停止提取")) { showCancelAlert = true }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }

    // MARK: 结果页

    private func resultScreen(_ result: MacFaceExtractResult) -> some View {
        VStack(spacing: 0) {
            header(
                title: T("提取完成"),
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Button(isExporting ? T("导出中…") : (exportedCount != nil ? T("已导出") : T("导出到文件夹…"))) {
                            export(result)
                        }
                        .buttonStyle(MacAccentButtonStyle())
                        .disabled(isExporting || exportedCount != nil)
                        Button(T("关闭")) { onClose() }
                            .buttonStyle(.bordered)
                    }
                )
            )

            HStack(spacing: 10) {
                infoChip(icon: "person.2", text: T("共 {1} 张", result.faces.count))
                infoChip(icon: "clock", text: T("时长 {1}", result.duration.timecode))
                infoChip(icon: "square.grid.3x3", text: T("3:4 裁切"))
                Spacer()
                Button(T("再提一次")) {
                    self.result = nil
                    exportedCount = nil
                    fileURL = nil
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, MacTheme.pagePadding)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                    spacing: 10
                ) {
                    ForEach(result.faces) { face in
                        Button {
                            previewFace = face
                        } label: {
                            Rectangle()
                                .fill(Color.black.opacity(0.3))
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .overlay {
                                    Image(nsImage: face.image)
                                        .resizable()
                                        .scaledToFill()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text(face.time.timecode)
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .padding(6)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(T("单击看大图"))
                    }
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.bottom, 24)
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

    private func previewOverlay(_ face: MacExtractedFace) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(nsImage: face.image)
                .resizable()
                .scaledToFit()
                .padding(24)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        previewFace = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.top, 12)
                }
                Spacer()
                Text(face.time.timecode)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: 流程

    private func autoStartIfNeeded() async {
        guard let debugURL, result == nil, !isProcessing, !isPreparing else { return }
        isPreparing = true
        fileURL = debugURL
        estimate = await MacFaceExtractor.estimate(url: debugURL, frameInterval: frameInterval)
        isPreparing = false
        if UserDefaults.standard.bool(forKey: "faceExtractSkipConfirm") {
            start()
        } else {
            showConfirm = true
        }
    }

    @MainActor
    private func pickVideo() {
        guard let url = MacAlerts.chooseVideoFile() else { return }
        isPreparing = true
        Task { @MainActor in
            fileURL = url
            estimate = await MacFaceExtractor.estimate(url: url, frameInterval: frameInterval)
            isPreparing = false
            showConfirm = true
        }
    }

    private func start() {
        guard let url = fileURL else { return }
        isProcessing = true
        progress = 0
        runTask = Task {
            do {
                let res = try await MacFaceExtractor.run(url: url, frameInterval: frameInterval) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run {
                    isProcessing = false
                    result = res
                    exportedCount = nil
                    autoExportIfNeeded(res)
                }
            } catch is CancellationError {
                await MainActor.run { isProcessing = false }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    if let extractError = error as? MacFaceExtractError, case .cancelled = extractError { return }
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

    private func export(_ result: MacFaceExtractResult) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = T("导出到这里")
        panel.message = T("选一个文件夹，人脸图会放进里面的子文件夹")
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        isExporting = true
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let folder = dir.appendingPathComponent(T("人脸提取-{1}", stamp.string(from: Date())), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = try MacFaceExtractor.write(faces: result.faces, to: folder)
            exportedCount = count
            showToast(T("已导出 {1} 张到「{2}」", count, folder.lastPathComponent))
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }

    /// Debug 钩子：`-faceExtractExportDir /tmp/face_out` 提取完直接写盘，方便验证导出链路。
    private func autoExportIfNeeded(_ result: MacFaceExtractResult) {
        guard let dir = UserDefaults.standard.string(forKey: "faceExtractExportDir") else { return }
        let folder = URL(fileURLWithPath: dir)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = try MacFaceExtractor.write(faces: result.faces, to: folder)
            exportedCount = count
            showToast(T("已导出 {1} 张到 {2}", count, folder.lastPathComponent))
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// 主色实心按钮（结果页的导出用到）
private struct MacAccentButtonStyle: ButtonStyle {
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

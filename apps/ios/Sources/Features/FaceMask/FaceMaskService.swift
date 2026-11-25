import AVFoundation
import CoreImage
import Foundation
import UIKit
import Vision

/// V3.6：一键人脸打码的四种遮挡方式。
enum FaceMaskStyle: String, CaseIterable, Identifiable {
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

enum FaceMaskPrefs {
    static let styleKey = "face.mask.style"
}

struct FaceMaskResult {
    let url: URL
    let duration: Double
    let faceCount: Int
    let framesWithFaces: Int
    let style: FaceMaskStyle
}

enum FaceMaskError: LocalizedError {
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

/// 逐帧检测人脸 + 按所选方式打码，最后重编码成新 mp4。
enum FaceMasker {

    /// 经验值：1080p/30fps 大约「每 2 帧检测一次」，耗时随分辨率与帧率线性增长。
    static func estimate(duration: Double, style: FaceMaskStyle) -> Double {
        let base = 1.5 + duration * 0.90
        return style == .blurNoise ? base + duration * 0.10 : base
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
        style: FaceMaskStyle,
        onProgress: @escaping (Double) -> Void
    ) async throws -> FaceMaskResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            throw FaceMaskError.noVideoTrack
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let orientedSize = transform.isQuarterTurn
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let nominalFPS = max((try? await videoTrack.load(.nominalFrameRate)) ?? 0, 1)
        let totalFrames = max(Int((duration * Double(nominalFPS)).rounded()), 1)

        // 读：视频逐帧 BGRA，音频直接透传
        let reader = try AVAssetReader(asset: asset)
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw FaceMaskError.readerFailed("无法读取视频轨道")
        }
        reader.add(videoOutput)

        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // 写：旋转后的画面 + 原音频
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("face-mask-\(UUID().uuidString).mp4")
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
            throw FaceMaskError.writerFailed("无法写入视频轨道")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting(), reader.startReading() else {
            throw FaceMaskError.writerFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "无法开始")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])

        // 检测在缩到 720 长边的画面上跑（太小的小脸会掉，太大又慢），全分辨率画面只用来渲染
        let detScale = min(1, 720 / max(orientedSize.width, orientedSize.height))
        #if DEBUG
        var tDetect = 0.0, tMask = 0.0, tRender = 0.0, tAppend = 0.0
        let runStart = Date()
        #endif
        var tracker = FaceTracker()
        var frameIndex = 0
        var framesWithFaces = 0
        #if DEBUG
        let mockDetect = UserDefaults.standard.bool(forKey: "faceMaskMock")
        let detector = FaceDetector(mock: mockDetect)
        #else
        let detector = FaceDetector()
        #endif
        // 检测节奏：按实测耗时自适应，慢机器自动放稀，快机器自动加密
        var stride = 3
        var lastDetectCost = 0.0

        while let sample = videoOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw FaceMaskError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)

            autoreleasepool {
                let base = makingUprightImage(
                    pixelBuffer: pixelBuffer,
                    transform: transform,
                    size: orientedSize
                )

                if frameIndex % stride == 0 {
                    #if DEBUG
                    let t1 = Date()
                    #endif
                    let small = base.transformedByScale(detScale)
                    // base 已经按 preferredTransform 摆正，方向固定 .up，不能再传 transform（会转两遍）
                    let observations = detector.detect(image: small)
                    tracker.update(observations: observations, frame: frameIndex, maxAge: stride * 2 + 4)
                    #if DEBUG
                    let cost = Date().timeIntervalSince(t1)
                    tDetect += cost
                    lastDetectCost = lastDetectCost == 0 ? cost : lastDetectCost * 0.7 + cost * 0.3
                    if lastDetectCost > 0.12 { stride = min(8, stride + 1) }
                    else if lastDetectCost < 0.04 { stride = max(2, stride - 1) }
                    #endif
                }

                let rects = tracker.rects(at: frameIndex, viewSize: orientedSize, maxAge: stride * 2 + 4)
                #if DEBUG
                if frameIndex % 30 == 0 {
                    NSLog("FACEMASK frame %d size=%.0fx%.0f rects=%@", frameIndex, orientedSize.width, orientedSize.height, rects.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }.joined(separator: " | "))
                }
                #endif
                if !rects.isEmpty { framesWithFaces += 1 }

                #if DEBUG
                let t2 = Date()
                #endif
                let masked = applyMasks(to: base, rects: rects, size: orientedSize, style: style, context: context)
                #if DEBUG
                tMask += Date().timeIntervalSince(t2)
                #endif

                if let pool = adaptor.pixelBufferPool {
                    var target: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
                    if let target {
                        #if DEBUG
                        let t3 = Date()
                        #endif
                        context.render(masked, to: target, bounds: CGRect(origin: .zero, size: orientedSize), colorSpace: CGColorSpaceCreateDeviceRGB())
                        #if DEBUG
                        tRender += Date().timeIntervalSince(t3)
                        #endif
                        while !videoInput.isReadyForMoreMediaData {
                            usleep(3000)
                        }
                        #if DEBUG
                        let t4 = Date()
                        #endif
                        adaptor.append(target, withPresentationTime: presentation)
                        #if DEBUG
                        tAppend += Date().timeIntervalSince(t4)
                        #endif
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

        // 音频透传（视频写完再补，AVAssetWriter 允许各轨道各自单调追加）
        if let audioInput, let audioOutput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData {
                    usleep(3000)
                }
                if audioInput.append(sample) == false { break }
            }
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        onProgress(1)

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw FaceMaskError.writerFailed(writer.error?.localizedDescription ?? "写入未完成")
        }
        if tracker.totalFaces == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            throw FaceMaskError.noFaceFound
        }

        #if DEBUG
        NSLog("FACEMASK timing total=%.1fs frames=%d detect=%.1fs mask=%.1fs render=%.1fs append=%.1fs faces=%d",
              Date().timeIntervalSince(runStart), frameIndex, tDetect, tMask, tRender, tAppend, tracker.totalFaces)
        #endif

        return FaceMaskResult(
            url: outputURL,
            duration: duration,
            faceCount: tracker.totalFaces,
            framesWithFaces: framesWithFaces,
            style: style
        )
    }

    // MARK: - 画面处理

    private static func makingUprightImage(
        pixelBuffer: CVPixelBuffer,
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

    private static func applyMasks(
        to base: CIImage,
        rects: [CGRect],
        size: CGSize,
        style: FaceMaskStyle,
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
                let color = CIColor(red: 0.05, green: 0.05, blue: 0.06)
                patch = CIImage(color: color).cropped(to: rect)
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

// MARK: - 人脸检测

/// Vision 优先；环境里 Vision 人脸模型起不来时（模拟器常见），自动退回 Core Image 的人脸检测
private final class FaceDetector {

    private enum Backend {
        case visionGPU
        case visionCPU
        case coreImage
        case dead
    }

    private var backend: Backend
    private let mock: Bool

    init(mock: Bool = false) {
        self.mock = mock
        #if targetEnvironment(simulator)
        // 部分 Intel Mac 上的模拟器建不了 GPU/Metal 推理上下文，直接走 CPU 推理
        backend = .visionCPU
        #else
        backend = .visionGPU
        #endif
    }

    private let gpuRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    /// Vision 在 iOS 16 之后没有公开的「只用 CPU」开关，`usesCPUOnly` 虽然标记废弃但仍是唯一可用入口。
    /// 它只在 GPU 推理上下文建不起来时兜底，正常设备不会走到这里。
    private let cpuRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        request.usesCPUOnly = true
        return request
    }()

    /// 用序列处理器而不是每帧新建 handler，Vision 才会给出跨帧稳定的 uuid（人脸计数、轨迹都靠它）
    private let sequenceHandler = VNSequenceRequestHandler()

    private lazy var ciDetector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    /// 返回 (稳定 id, 归一化框)，框以左下角为原点，跟 Vision 一致。
    /// 传入的 image 必须已经按视频的 preferredTransform 摆正，所以这里方向固定 .up。
    func detect(image: CIImage) -> [(UUID?, CGRect)] {
        #if DEBUG
        if mock { return [(nil, CGRect(x: 0.28, y: 0.42, width: 0.44, height: 0.44))] }
        #endif

        while true {
            switch backend {
            case .visionGPU:
                if let faces = run(gpuRequest, on: image) { return faces }
                backend = .visionCPU
            case .visionCPU:
                if let faces = run(cpuRequest, on: image) { return faces }
                backend = .coreImage
            case .coreImage:
                return detectWithCoreImage(image)
            case .dead:
                return []
            }
        }
    }

    private func run(_ request: VNRequest, on image: CIImage) -> [(UUID?, CGRect)]? {
        do {
            try sequenceHandler.perform([request], on: image, orientation: .up)
            let faces = (request.results as? [VNFaceObservation]) ?? []
            #if DEBUG
            if FaceDetector.logBudget > 0 {
                FaceDetector.logBudget -= 1
                NSLog("FACEMASK vision faces=%d size=%.0fx%.0f", faces.count, image.extent.width, image.extent.height)
            }
            #endif
            return faces.map { ($0.uuid, $0.boundingBox) }
        } catch {
            #if DEBUG
            NSLog("FACEMASK vision unavailable: %@", error.localizedDescription)
            #endif
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
        #if DEBUG
        if FaceDetector.logBudget > 0 {
            FaceDetector.logBudget -= 1
            NSLog("FACEMASK CI detect size=%.0fx%.0f features=%d", extent.width, extent.height, features.count)
        }
        #endif
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

    #if DEBUG
    static var logBudget = 6
    #endif
}

// MARK: - 轨迹跟踪

private struct TrackedFace {
    /// 归一化框（左下角原点，y 向上）
    var rect: CGRect
    var lastFrame: Int
}

private struct FaceTracker {
    private var tracks: [UUID: TrackedFace] = [:]
    /// 出现过的不同人脸数量（同一张脸被换过 id 也不会重复计数）
    private(set) var totalFaces = 0

    /// Vision 每帧给的 uuid 在跳帧检测时并不稳定，所以统一按位置把脸串起来，uuid 只当辅助。
    mutating func update(observations: [(UUID?, CGRect)], frame: Int, maxAge: Int) {
        var claimed = Set<UUID>()

        for (uuid, rect) in observations {
            // 1) uuid 能直接对上就用它
            if let uuid, tracks[uuid] != nil, !claimed.contains(uuid) {
                claimed.insert(uuid)
                tracks[uuid] = TrackedFace(rect: blend(tracks[uuid]!.rect, rect, keep: 0.7), lastFrame: frame)
                continue
            }
            // 2) 否则按中心距离找最近的一条轨迹
            if let match = nearest(to: rect, excluding: claimed) {
                claimed.insert(match)
                tracks[match] = TrackedFace(rect: blend(tracks[match]!.rect, rect, keep: 0.7), lastFrame: frame)
            } else {
                let id = UUID()
                tracks[id] = TrackedFace(rect: rect, lastFrame: frame)
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
            // CI 坐标原点在左下角，跟检测框的归一化坐标同一套方向，直接乘尺寸即可
            let pixel = CGRect(
                x: normalized.minX * viewSize.width,
                y: normalized.minY * viewSize.height,
                width: normalized.width * viewSize.width,
                height: normalized.height * viewSize.height
            )
            let rect = pixel.expanded(by: 0.28).clamped(in: CGRect(origin: .zero, size: viewSize))
            guard !rect.isEmpty else { continue }
            // 同一张脸偶尔会留下两条轨迹，重叠度高的只保留一条
            if result.contains(where: { $0.overlapRatio(with: rect) > 0.6 }) { continue }
            result.append(rect)
        }
        return result
    }

    private func nearest(to rect: CGRect, excluding claimed: Set<UUID>) -> UUID? {
        var best: (UUID, CGFloat)?
        for (id, tracked) in tracks where !claimed.contains(id) {
            // 允许两帧之间脸移动「半个脸宽」
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
    func transformedByScale(_ scale: CGFloat) -> CIImage {
        guard scale != 1 else { return self }
        return transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: extent.size.applying(CGAffineTransform(scaleX: scale, y: scale))))
    }
}

private extension CGRect {
    var area: CGFloat { width * height }

    func overlapRatio(with other: CGRect) -> CGFloat {
        guard intersects(other) else { return 0 }
        let shared = intersection(other)
        return shared.width * shared.height / max(area, 1)
    }

    func expanded(by ratio: CGFloat) -> CGRect {
        insetBy(dx: -size.width * ratio, dy: -size.height * ratio)
    }

    func clamped(in bounds: CGRect) -> CGRect {
        let rect = self.intersection(bounds)
        return rect.isNull || rect.isEmpty ? .zero : rect
    }
}

private extension CGAffineTransform {
    var isQuarterTurn: Bool {
        let angle = atan2(b, a)
        let degrees = Int((angle * 180 / .pi).rounded())
        return abs(degrees) == 90 || abs(degrees) == 270
    }
}

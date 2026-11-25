import AVFoundation
import CoreImage
import Photos
import UIKit
import Vision

/// V3.8：一键提取人脸。把视频里出现过的脸裁成一张张图片，同一张脸只留质量最好的一张。
struct ExtractedFace: Identifiable {
    let id = UUID()
    let image: UIImage
    /// 在视频里第一次出现的时间（秒）
    let time: Double
    /// Vision 的画面质量分，用来在同一张脸的多帧里挑最好的
    let quality: Float
}

struct FaceExtractResult {
    let faces: [ExtractedFace]
    let duration: Double
}

enum FaceExtractError: LocalizedError {
    case noVideoTrack
    case noFaceFound
    case readerFailed(String)
    case saveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频画面"
        case .noFaceFound: return "整段视频没有检测到清晰的人脸"
        case .readerFailed(let reason): return "读取视频失败：\(reason)"
        case .saveFailed(let reason): return "保存失败：\(reason)"
        case .cancelled: return "已取消"
        }
    }
}

enum FaceExtractor {

    /// 取帧间隔（秒）：1 秒取 1 帧是最细的一档，最粗 10 秒取 1 帧。
    static let frameIntervalRange: ClosedRange<Double> = 1...10
    static let defaultFrameInterval: Double = 1
    /// 结果上限，避免几十号人的长视频生成上百张图
    static let maxFaces = 80
    /// 人脸最短边小于这个像素就丢掉（画面里的小路人脸裁出来也没用）
    private static let minFacePixels: CGFloat = 48

    /// 估时结果：视频时长、要抽检的帧数、预估耗时
    struct Estimate {
        let duration: Double
        let frames: Int
        let seconds: Double
        let interval: Double

        /// 弹框第一行：「视频 00:08 · 每 1 秒 1 帧 · 8 帧」
        var summary: String {
            let intervalText = "每 \(Int(interval)) 秒 1 帧"
            return duration > 0
                ? "视频 \(duration.timecode) · \(intervalText) · \(frames) 帧"
                : "\(intervalText) · \(frames) 帧"
        }

        /// 「约 6 秒」
        var durationLabel: String { FaceExtractor.estimateLabel(seconds) }
    }

    /// 拿不到实测速度时的兜底：每帧 60ms（真机 Vision 的真实量级）
    private static let fallbackSecondsPerFrame: Double = 0.06

    /// 真正动手前先用中间帧实测一次检测耗时，按本机速度（模拟器 / 真机差好几倍）折算整段耗时。
    static func estimate(url: URL, frameInterval: Double = defaultFrameInterval) async -> Estimate {
        let interval = clamp(frameInterval, 1, 10)
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let frames = max(1, Int((duration / interval).rounded(.up)))
        let perFrame = (await probeSecondsPerFrame(url: url)) ?? fallbackSecondsPerFrame
        // 每帧还要解码摆正；检测到的脸再做裁切，乘 1.25 兜这部分
        let seconds = clamp(1.0 + Double(frames) * perFrame * 1.25, 2, 900)
        return Estimate(duration: duration, frames: frames, seconds: seconds, interval: interval)
    }

    static func estimateLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "约 \(Int(seconds.rounded(.up))) 秒" }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if rest == 0 { return "约 \(minutes) 分钟" }
        return "约 \(minutes) 分 \(rest) 秒"
    }

    /// 从视频中间取两帧跑检测并计时：第一帧含模型初始化，取第二帧的耗时当每帧成本。
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
        // 第一帧含模型初始化，丢掉；后面几帧取平均，避免单帧抖动把估时带偏
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
        /// 摆正之后（rotation 已换算进去）的画面尺寸
        let size: CGSize
    }

    /// 统一用 iOS 16 的异步 load 接口取轨道 / 方向 / 尺寸，避免同步弃用 API 的告警
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
    ) async throws -> FaceExtractResult {
        let asset = AVURLAsset(url: url)
        guard let geometry = await videoGeometry(of: asset) else {
            throw FaceExtractError.noVideoTrack
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
            throw FaceExtractError.readerFailed("无法读取视频轨道")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FaceExtractError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        let interval = clamp(frameInterval, 1, 10)
        // 相邻两帧最多隔 interval 秒，轨迹的连续窗口必须比它宽，否则稀疏取样时每帧都开一条新轨迹
        let trackWindow = max(1.6, interval * 1.5)
        let context = CIContext(options: [.cacheIntermediates: false])
        let detector = Detector()
        // 检测在 720 长边上跑：全分辨率只用来裁图，检测快了精度也够
        let detScale = min(1, 720 / max(orientedSize.width, orientedSize.height))

        var faces: [ExtractedFace] = []
        var tracks: [Track] = []
        var lastSample: Double = -1

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw FaceExtractError.cancelled
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
                    let faceImage = UIImage(cgImage: cgImage)

                    // 和已有轨迹比对：位置重叠 + 时间相邻 → 认为是同一张脸，只在质量更好时替换
                    if let index = tracks.firstIndex(where: {
                        $0.lastTime > pts - trackWindow && overlap($0.rect, crop) > 0.35
                    }) {
                        tracks[index].rect = crop
                        tracks[index].lastTime = pts
                        let faceIndex = tracks[index].faceIndex
                        if quality > faces[faceIndex].quality + 0.06 {
                            faces[faceIndex] = ExtractedFace(
                                image: faceImage,
                                time: faces[faceIndex].time,
                                quality: quality
                            )
                        }
                    } else {
                        faces.append(ExtractedFace(image: faceImage, time: pts, quality: quality))
                        tracks.append(Track(rect: crop, lastTime: pts, faceIndex: faces.count - 1))
                    }
                }
            }

            onProgress(min(max(pts / max(duration, 0.01), 0), 0.99))
        }

        if reader.status == .failed {
            throw FaceExtractError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        guard !faces.isEmpty else { throw FaceExtractError.noFaceFound }

        let sorted = faces.sorted { $0.time < $1.time }
        let limited = sorted.count > maxFaces
            ? sorted.sorted { $0.quality > $1.quality }.prefix(maxFaces).sorted { $0.time < $1.time }
            : sorted
        onProgress(1)
        return FaceExtractResult(faces: Array(limited), duration: duration)
    }

    /// 全部写进系统相册，返回实际写入的张数。
    static func save(faces: [ExtractedFace]) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw FaceExtractError.saveFailed("没有相册写入权限，请到系统设置里允许后再试")
        }
        let data = faces.compactMap { $0.image.jpegData(compressionQuality: 0.92) }
        guard !data.isEmpty else { throw FaceExtractError.saveFailed("没有可保存的图片") }
        try await PHPhotoLibrary.shared().performChanges {
            for item in data {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = Date()
                request.addResource(with: .photo, data: item, options: nil)
            }
        }
        return data.count
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

    /// 以脸为中心裁一块 3:4 竖图：脸高 ×2，再往上偏一点把头发和额头带全
    private static func cropRect(around face: CGRect, in size: CGSize) -> CGRect {
        let height = min(size.height, max(face.height * 2, 120))
        let width = min(size.width, height * 0.75)
        let centerY = face.midY + face.height * 0.15
        var rect = CGRect(
            x: face.midX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > size.width { rect.origin.x = size.width - rect.width }
        if rect.maxY > size.height { rect.origin.y = size.height - rect.height }
        return rect
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        guard union > 0 else { return 0 }
        return inter.width * inter.height / union
    }

    // MARK: - 人脸检测（Vision 优先，失败逐级降级，模拟器里退回 Core Image）

    /// 每段视频建一个：后端一旦降级就不再回头试，避免每帧都白跑一次失败请求。
    private final class Detector {
        enum Backend {
            case qualityGPU, qualityCPU, rectGPU, rectCPU, coreImage, dead
        }

        var backend: Backend = .qualityGPU
        /// 序列处理器复用，Vision 才会给出跨帧稳定的 uuid
        private let handler = VNSequenceRequestHandler()

        private let qualityGPU: VNDetectFaceCaptureQualityRequest = {
            let request = VNDetectFaceCaptureQualityRequest()
            request.revision = VNDetectFaceCaptureQualityRequestRevision1
            return request
        }()

        /// `usesCPUOnly` 在 iOS 16 起标记废弃，但仍是唯一公开的「只用 CPU」入口；
        /// 这台 Intel Mac 的模拟器建不了 GPU 推理上下文，只有 CPU 推理能出结果。
        private let qualityCPU: VNDetectFaceCaptureQualityRequest = {
            let request = VNDetectFaceCaptureQualityRequest()
            request.revision = VNDetectFaceCaptureQualityRequestRevision1
            request.usesCPUOnly = true
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
            request.usesCPUOnly = true
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
                #if DEBUG
                NSLog("FACEEXTRACT vision unavailable: %@", error.localizedDescription)
                #endif
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

enum FaceExtractPrefs {
    private static let intervalKey = "face.extract.interval"

    /// 取帧间隔（秒），限制在 1…10
    static var frameInterval: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            guard stored > 0 else { return FaceExtractor.defaultFrameInterval }
            return min(max(stored, 1), 10)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), 10), forKey: intervalKey)
        }
    }
}

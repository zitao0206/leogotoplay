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

    /// 每秒抽 3 帧做检测：再密就只是重复同一张脸，再稀容易漏掉一闪而过的人。
    static let samplesPerSecond: Double = 3
    /// 结果上限，避免几十号人的长视频生成上百张图
    static let maxFaces = 80
    /// 人脸最短边小于这个像素就丢掉（画面里的小路人脸裁出来也没用）
    private static let minFacePixels: CGFloat = 48

    static func estimate(duration: Double) -> Double {
        1.2 + duration * 0.16
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
        onProgress: @escaping (Double) -> Void
    ) async throws -> FaceExtractResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw FaceExtractError.noVideoTrack
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let transform = videoTrack.preferredTransform
        let naturalSize = videoTrack.naturalSize
        let orientedSize = transform.isQuarterTurn
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        guard orientedSize.width > 1, orientedSize.height > 1 else {
            throw FaceExtractError.readerFailed("画面尺寸异常")
        }

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
            if lastSample >= 0, pts - lastSample < (1 / samplesPerSecond) - 0.001 { continue }
            lastSample = pts

            try autoreleasepool {
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
                        $0.lastTime > pts - 1.6 && overlap($0.rect, crop) > 0.35
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

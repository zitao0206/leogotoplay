import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 缩略图 / 时间轴胶片帧生成（跨平台：只产出 CGImage，不依赖 UIKit / AppKit）。
public enum ThumbnailService {

    /// 为视频生成封面缩略图，成功后返回沙盒内的文件名。
    public static func generateCover(forVideoAt url: URL, at seconds: Double = 0) async -> String? {
        let name = "\(UUID().uuidString).jpg"
        let destination = VideoFileStore.shared.thumbnailURL(named: name)

        let cgImage: CGImage? = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            // V2.7.16：封面必须是「第一帧」。之前给 1s + 0.5s 容差，系统会挑最近的关键帧，
            // 列表里看到的往往是 1s 出头那一帧。先按零容差取 0s，极少数素材解不出来再退一步。
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                return image
            }
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }.value

        guard let cgImage else { return nil }
        guard Self.writeJPEG(cgImage, to: destination) else { return nil }
        return name
    }

    /// 生成时间轴胶片帧（不落盘，仅用于编辑器预览）。
    public static func generateFrames(forVideoAt url: URL, duration: Double, count: Int) async -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

            var frames: [CGImage] = []
            let step = duration / Double(count)
            for index in 0..<count {
                let seconds = min(step * Double(index) + step / 2, max(duration - 0.01, 0))
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    frames.append(cgImage)
                }
            }
            return frames
        }.value
    }

    /// 时间轴胶片帧（流式）：请求一次性批量提交给系统并行解码，出图立刻通过 `onFrame` 回调，
    /// 调用方可以边收边画，不必等整条胶片生成完；返回值是按下标对齐的完整结果（失败的帧为 nil）。
    @discardableResult
    public static func generateFramesStreaming(
        forVideoAt url: URL,
        duration: Double,
        count: Int,
        onFrame: @escaping (Int, CGImage) -> Void
    ) async -> [CGImage?] {
        guard duration > 0, count > 0 else { return [] }
        let step = duration / Double(count)
        let seconds: [Double] = (0..<count).map { index in
            min(step * Double(index) + step / 2, max(duration - 0.01, 0))
        }
        return await generateFramesStreaming(forVideoAt: url, times: seconds, onFrame: onFrame)
    }

    /// 同上，但每一格取图的时间点由调用方直接给（用于按「成片时间」重排胶片）。
    @discardableResult
    public static func generateFramesStreaming(
        forVideoAt url: URL,
        times secondsList: [Double],
        onFrame: @escaping (Int, CGImage) -> Void
    ) async -> [CGImage?] {
        let count = secondsList.count
        guard count > 0 else { return [] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 胶片条只要形似，尺寸压到 160、容差放到最大，直接取最近的关键帧，出图快一个数量级
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        var times: [NSValue] = []
        var indexByKey: [String: Int] = [:]
        for (index, seconds) in secondsList.enumerated() {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            indexByKey["\(time.value)-\(time.timescale)"] = index
            times.append(NSValue(time: time))
        }

        final class Collector {
            let lock = NSLock()
            var slots: [CGImage?]
            var remaining: Int
            init(count: Int) {
                slots = Array(repeating: nil, count: count)
                remaining = count
            }
        }
        let collector = Collector(count: count)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
                let key = "\(requested.value)-\(requested.timescale)"
                let index = indexByKey[key]
                collector.lock.lock()
                if let index, let image, collector.slots[index] == nil {
                    collector.slots[index] = image
                    collector.lock.unlock()
                    onFrame(index, image)
                } else {
                    collector.lock.unlock()
                }
                collector.lock.lock()
                collector.remaining -= 1
                let finished = collector.remaining <= 0
                collector.lock.unlock()
                if finished { continuation.resume() }
            }
        }

        collector.lock.lock()
        defer { collector.lock.unlock() }
        return collector.slots
    }

    // MARK: - Private

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return false }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

import AVFoundation
import SwiftUI
import LeogotoPlayCore

/// 剪辑器 ViewModel：负责预览播放、裁剪区间、导出。
@MainActor
final class EditorViewModel: ObservableObject {

    /// 剪辑来源：素材库已有视频，或从相册 / 文件临时导入的视频。
    struct Source {
        enum Kind {
            case library(VideoItem)
            case temporary(URL)
        }

        let kind: Kind
        let url: URL
        let title: String

        static func library(_ item: VideoItem) -> Source {
            Source(kind: .library(item), url: item.fileURL, title: item.title)
        }

        static func temporary(_ url: URL, title: String) -> Source {
            Source(kind: .temporary(url), url: url, title: title)
        }

        var libraryItem: VideoItem? {
            if case .library(let item) = kind { return item }
            return nil
        }

        var isTemporary: Bool {
            if case .temporary = kind { return true }
            return false
        }
    }

    let source: Source
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var isAspectFill = true
    @Published var filmstrip: [UIImage] = []
    @Published var isLoading = true
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(source: Source) {
        self.source = source
        self.player = AVPlayer(url: source.url)
        player.isMuted = false
        observePlayer()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    var selectedDuration: Double { max(0, trimEnd - trimStart) }

    func load() async {
        isLoading = true
        duration = await VideoImporter.duration(of: source.url)
        if duration <= 0 { duration = 0.01 }
        trimStart = 0
        trimEnd = duration
        filmstrip = await ThumbnailService.generateFrames(forVideoAt: source.url, duration: duration, count: 8)
            .map { UIImage(cgImage: $0) }
        isLoading = false
        seek(to: 0)
    }

    // MARK: - 播放控制

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// 拖动左右手柄时同步更新区间，并预览起点画面。
    func updateTrim(start: Double) {
        let minGap = minTrimGap
        trimStart = min(max(0, start), max(0, trimEnd - minGap))
        seek(to: trimStart)
    }

    func updateTrim(end: Double) {
        let minGap = minTrimGap
        trimEnd = max(min(duration, end), min(duration, trimStart + minGap))
        seek(to: trimEnd - 0.02)
    }

    var minTrimGap: Double {
        min(0.2, max(0.05, duration * 0.01))
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
    }

    // MARK: - 导出

    /// 导出当前裁剪结果到临时目录，返回文件 URL。
    func export() async -> URL? {
        guard selectedDuration > 0.1 else {
            errorMessage = "裁剪区间太短，至少需要 0.1 秒"
            return nil
        }
        guard !isExporting else { return nil }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        do {
            let url = try await VideoExporter.export(
                videoURL: source.url,
                trimRange: trimStart...trimEnd,
                isMuted: isMuted,
                quality: ExportSettings.quality,
                progressHandler: { [weak self] progress in
                    self?.exportProgress = progress
                }
            )
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - 播放监听

    private func observePlayer() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor in self.handleTick(seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.isPlaying = false }
        }
    }

    private func handleTick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, seconds >= trimEnd - 0.03 {
            seek(to: trimStart)
        }
    }
}

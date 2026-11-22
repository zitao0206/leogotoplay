import AVFoundation
import SwiftUI
import LeogotoPlayCore

/// V1.1.0：循环模式。
enum PlaybackMode: String, CaseIterable, Identifiable {
    /// 单曲循环（默认）
    case repeatOne
    /// 当前列表循环播放
    case listLoop
    /// 列表顺序播放，放完停止
    case listOnce
    /// 单曲播放，放完停止
    case stopAtEnd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repeatOne: "单曲循环"
        case .listLoop: "文件夹循环"
        case .listOnce: "列表播放"
        case .stopAtEnd: "单曲停止"
        }
    }

    var icon: String {
        switch self {
        case .repeatOne: "repeat.1"
        case .listLoop: "repeat"
        case .listOnce: "list.bullet"
        case .stopAtEnd: "stop.circle"
        }
    }
}

/// 播放页 ViewModel：播放 / 暂停 / 进度 / 倍速 / 循环模式 / 上一个下一个。
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var item: VideoItem
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double
    /// 0.25x ... 5x
    @Published var rate: Float = 1
    @Published var mode: PlaybackMode = .repeatOne
    /// V2.3：默认按视频原始比例完整显示（不裁切）。
    @Published var isAspectFill = false
    /// 拿不到系统音量滑杆时用的播放器自身音量（0...1）。
    @Published var playerVolume: Float = 1

    /// 当前播放队列（同一个文件夹内的视频），供列表循环 / 上一个下一个使用。
    @Published private(set) var queue: [VideoItem]
    private var index: Int

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    static let minRate: Float = 0.25
    static let maxRate: Float = 5

    init(item: VideoItem, queue: [VideoItem] = []) {
        self.item = item
        let resolved = queue.isEmpty ? [item] : queue
        self.queue = resolved
        self.index = resolved.firstIndex(where: { $0.id == item.id }) ?? 0
        duration = max(item.duration, 0.01)
        player = AVPlayer(url: item.fileURL)
        observe()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - 文案

    var rateLabel: String {
        var text = String(format: "%.2f", rate)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "x"
    }

    var hasQueue: Bool { queue.count > 1 }

    // MARK: - 队列

    /// 进入播放器后由页面注入同目录视频列表。
    func setQueue(_ items: [VideoItem]) {
        guard !items.isEmpty else { return }
        queue = items
        index = items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    func playPrevious() {
        guard hasQueue else {
            seek(to: 0)
            return
        }
        index = (index - 1 + queue.count) % queue.count
        load(queue[index], autoplay: true)
    }

    func playNext() {
        guard hasQueue else {
            seek(to: 0)
            return
        }
        index = (index + 1) % queue.count
        load(queue[index], autoplay: true)
    }

    private func advanceIfPossible(wrapping: Bool) {
        if index + 1 < queue.count {
            index += 1
            load(queue[index], autoplay: true)
        } else if wrapping, !queue.isEmpty {
            index = 0
            load(queue[index], autoplay: true)
        } else {
            stopAtEnd()
        }
    }

    private func load(_ newItem: VideoItem, autoplay: Bool) {
        player.pause()
        item = newItem
        duration = max(newItem.duration, 0.01)
        currentTime = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: newItem.fileURL))
        if autoplay {
            player.playImmediately(atRate: rate)
            isPlaying = true
            Task { await reloadDuration() }
        } else {
            isPlaying = false
        }
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
        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 前进 / 倒退，传负数即倒退。
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ value: Float) {
        rate = min(max(value, Self.minRate), Self.maxRate)
        if isPlaying {
            player.rate = rate
        }
    }

    func setVolume(_ value: Float) {
        playerVolume = min(max(value, 0), 1)
        player.volume = playerVolume
    }

    func setMode(_ value: PlaybackMode) {
        mode = value
    }

    func reloadDuration() async {
        let latest = await VideoImporter.duration(of: item.fileURL)
        if latest > 0, abs(latest - duration) > 0.05 {
            duration = latest
        }
    }

    // MARK: - 监听

    private func observe() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor in self.tick(seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let endedItem = note.object as? AVPlayerItem
            Task { @MainActor in
                guard endedItem === self.player.currentItem else { return }
                self.handleEnd()
            }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
    }

    private func handleEnd() {
        switch mode {
        case .repeatOne:
            player.seek(to: .zero)
            player.playImmediately(atRate: rate)
            isPlaying = true
        case .listLoop:
            if hasQueue {
                advanceIfPossible(wrapping: true)
            } else {
                player.seek(to: .zero)
                player.playImmediately(atRate: rate)
                isPlaying = true
            }
        case .listOnce:
            if hasQueue {
                advanceIfPossible(wrapping: false)
            } else {
                stopAtEnd()
            }
        case .stopAtEnd:
            stopAtEnd()
        }
    }

    private func stopAtEnd() {
        player.pause()
        isPlaying = false
        currentTime = duration
    }
}

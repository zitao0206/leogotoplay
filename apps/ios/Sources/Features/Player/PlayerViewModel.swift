import AVFoundation
import SwiftUI
import LeogotoPlayCore

/// 播放页 ViewModel：播放 / 暂停 / 进度 / 倍速 / 循环 / 画面填充。
@MainActor
final class PlayerViewModel: ObservableObject {
    let item: VideoItem
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double
    @Published var rate: Float = 1
    @Published var isLooping = true
    @Published var isAspectFill = true

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private let rates: [Float] = [0.5, 1, 1.5, 2]

    init(item: VideoItem) {
        self.item = item
        duration = max(item.duration, 0.01)
        player = AVPlayer(url: item.fileURL)
        isLooping = UserDefaults.standard.object(forKey: ExportSettings.autoLoopKey) as? Bool ?? true
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

    var availableRates: [Float] { rates }

    var rateLabel: String {
        rate == 1 ? "1x" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))x" : String(format: "%.1fx", rate))
    }

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

    func setRate(_ value: Float) {
        rate = value
        if isPlaying {
            player.rate = value
        }
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
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleEnd() }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, isLooping, seconds >= duration - 0.05 {
            player.seek(to: .zero)
        }
    }

    private func handleEnd() {
        if isLooping {
            player.seek(to: .zero)
            player.playImmediately(atRate: rate)
            isPlaying = true
        } else {
            isPlaying = false
            currentTime = duration
        }
    }
}

import AVFoundation
import SwiftUI
import LeogotoPlayCore

/// macOS 播放器窗口（sheet 形式）：AVPlayerLayer 画面 + 自绘控制条。
struct MacPlayerView: View {
    let item: VideoItem

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExportSettings.autoLoopKey) private var autoLoop = false

    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    init(item: VideoItem) {
        self.item = item
        _player = State(initialValue: AVPlayer(url: item.fileURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black
                MacPlayerSurface(player: player)
            }
            .frame(minWidth: 720, minHeight: 460)
            controlBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text("\(item.duration.timecode) · \(item.fileSize.fileSizeText) · \(item.source.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("循环播放", isOn: $autoLoop)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                isPlaying ? pause() : play()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderedProminent)

            Text(progress.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { progress },
                set: { seek(to: $0) }
            ), in: 0...max(item.duration, 0.01))

            Text(item.duration.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 播放控制

    private func start() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            progress = seconds
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            if autoLoop {
                player.seek(to: .zero)
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
        }

        play()
    }

    private func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func play() {
        if progress >= item.duration - 0.05 {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    private func pause() {
        player.pause()
        isPlaying = false
    }

    private func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), item.duration)
        progress = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }
}

import AVFoundation
import AVKit
import AppKit
import SwiftUI
import LeogotoPlayCore

// MARK: - 播放窗口（V3.1.0）

/// 播放器独立开窗：黑底、画面按原比例自适应铺满、底部悬浮控制面板（对齐参考稿）。
@MainActor
final class MacPlayerWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacPlayerWindowManager()

    private struct Entry {
        let window: NSWindow
        let videoID: UUID
    }

    private var entries: [Entry] = []

    func open(item: VideoItem, library: LibraryStore) {
        if let existing = entries.first(where: { $0.videoID == item.id }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = item.title
        // 标题由播放页自己画在最上方，窗口标题栏留空、透明
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 880, height: 520)
        window.center()
        window.delegate = self

        let root = MacPlayerView(item: item)
            .environmentObject(library)

        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        entries.append(Entry(window: window, videoID: item.id))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        entries.removeAll { $0.window === window }
    }
}

// MARK: - 播放页

struct MacPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(ExportSettings.autoLoopKey) private var autoLoop = false

    @State private var current: VideoItem
    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double
    @State private var volume: Double = 1
    @State private var rate: Double = 1
    @State private var showSpeedMenu = false
    @State private var showPlaylist = false
    @State private var toast: String?
    @State private var pipController: AVPictureInPictureController?

    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    init(item: VideoItem) {
        _current = State(initialValue: item)
        _duration = State(initialValue: item.duration)
        _player = State(initialValue: AVPlayer(url: item.fileURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 画面：AVPlayerLayer 用 resizeAspect，窗口怎么拖都按视频原始比例铺满
            MacPlayerSurface(player: player, onReady: { view in
                makePiPController(for: view)
            })
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                titleBar
                Spacer(minLength: 0)
                controlPanel
                    .padding(.bottom, 28)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(18)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: volume) { newValue in
            player.volume = Float(newValue)
        }
        .onChange(of: rate) { newValue in
            if isPlaying { player.rate = Float(newValue) }
        }
    }

    // MARK: - 顶部标题

    private var titleBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(current.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 90)
        .padding(.trailing, 56)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .trailing) {
            Button {
                togglePictureInPicture()
            } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("画中画")
            .disabled(pipController == nil)
            .padding(.trailing, 14)
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - 悬浮控制面板

    private var controlPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    volume = volume > 0 ? 0 : 1
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)

                Slider(value: $volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.85))
                    .frame(width: 96)

                Spacer(minLength: 0)

                transportButton("backward.end.fill", size: 15, tip: "上一个") { step(by: -1) }
                transportButton(isPlaying ? "pause.fill" : "play.fill", size: 20, tip: isPlaying ? "暂停" : "播放") {
                    isPlaying ? pause() : play()
                }
                .keyboardShortcut(.space, modifiers: [])
                transportButton("forward.end.fill", size: 15, tip: "下一个") { step(by: 1) }

                Spacer(minLength: 0)

                transportButton("camera", size: 15, tip: "截取当前帧") { captureFrame() }

                Button {
                    showSpeedMenu.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showSpeedMenu ? MacTheme.accent : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("播放设置")
                .popover(isPresented: $showSpeedMenu, arrowEdge: .bottom) {
                    speedMenu
                }

                Button {
                    showPlaylist.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showPlaylist ? MacTheme.accent : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("播放列表")
                .popover(isPresented: $showPlaylist, arrowEdge: .bottom) {
                    playlist
                }
            }

            HStack(spacing: 10) {
                Text(Self.hms(progress))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 62, alignment: .leading)

                MacPlayerProgressBar(value: progress, duration: max(duration, 0.01)) { target in
                    seek(to: target)
                }

                Text(Self.hms(duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.14).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .foregroundStyle(.white)
    }

    private var volumeIcon: String {
        if volume <= 0.001 { return "speaker.slash" }
        if volume < 0.4 { return "speaker.wave.1" }
        if volume < 0.8 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    private func transportButton(_ symbol: String, size: CGFloat, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var speedMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                Button {
                    rate = value
                    showSpeedMenu = false
                } label: {
                    HStack {
                        Text(value == 1.0 ? "正常速度" : String(format: "%.1f×", value))
                        Spacer()
                        if rate == value {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(width: 120, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider().padding(.vertical, 3)

            Toggle("循环播放", isOn: $autoLoop)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .font(.system(size: 12))
        .padding(6)
    }

    private var playlist: some View {
        let items = playlistItems
        return VStack(alignment: .leading, spacing: 0) {
            Text("播放列表 · \(items.count) 个视频")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { video in
                        Button {
                            showPlaylist = false
                            if video.id != current.id { load(video) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: video.id == current.id ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(video.id == current.id ? MacTheme.accent : .secondary)
                                    .frame(width: 12)
                                Text(video.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(video.duration.timecode)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 280)
        .padding(6)
    }

    private var playlistItems: [VideoItem] {
        let scope = library.videos(in: current.folderID)
        let list = scope.isEmpty ? library.videos(in: nil) : scope
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    /// 00:00:00 这种「时:分:秒」，和参考稿一致
    static func hms(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
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
            if let assetDuration = player.currentItem?.duration.seconds, assetDuration.isFinite, assetDuration > 0 {
                duration = assetDuration
            }
        }

        player.volume = Float(volume)
        observeEnd()
        play()
    }

    private func observeEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            if autoLoop {
                player.seek(to: .zero)
                player.rate = Float(rate)
                isPlaying = true
            } else {
                isPlaying = false
            }
        }
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
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
    }

    private func load(_ video: VideoItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        current = video
        duration = video.duration
        progress = 0
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: video.fileURL))
        observeEnd()
        play()
    }

    private func step(by offset: Int) {
        let items = playlistItems
        guard !items.isEmpty,
              let index = items.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (index + offset + items.count) % items.count
        load(items[next])
    }

    private func play() {
        if progress >= duration - 0.05 {
            player.seek(to: .zero)
        }
        player.rate = Float(rate)
        player.play()
        player.rate = Float(rate)
        isPlaying = true
    }

    private func pause() {
        player.pause()
        isPlaying = false
    }

    private func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(duration, 0.01))
        progress = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    // MARK: - 截图 / 画中画

    private func captureFrame() {
        guard let asset = player.currentItem?.asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            let image = try generator.copyCGImage(
                at: CMTime(seconds: progress, preferredTimescale: 600),
                actualTime: nil
            )
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "截图-\(formatter.string(from: Date())).png"
            let directory = FileManager.default
                .urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LeogotoPlay", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            toast = "已保存到 图片/LeogotoPlay/\(name)"
            dismissToast()
        } catch {
            toast = "截帧失败：\(error.localizedDescription)"
            dismissToast()
        }
    }

    private func dismissToast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }

    private func makePiPController(for view: MacPlayerLayerView) {
        guard pipController == nil,
              let layer = view.playerLayer,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pipController = AVPictureInPictureController(playerLayer: layer)
    }

    private func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }
}

// MARK: - 细进度条

private struct MacPlayerProgressBar: View {
    let value: Double
    let duration: Double
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = min(max(value / max(duration, 0.01), 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(2, width * fraction), height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .offset(x: min(max(width * fraction - 4.5, 0), width - 9))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let ratio = min(max(drag.location.x / width, 0), 1)
                        onScrub(ratio * duration)
                    }
            )
        }
        .frame(height: 18)
    }
}

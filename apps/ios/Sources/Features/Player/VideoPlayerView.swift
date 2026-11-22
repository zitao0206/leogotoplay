import SwiftUI
import LeogotoPlayCore

/// 播放器页：全屏播放 + 进度拖动 + 播放控制（上一个 / ±10s / 下一个）+ 循环模式 + 倍速滑块，可直接进入剪辑。
struct VideoPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: PlayerViewModel
    @State private var editorSource: EditorViewModel.Source?
    @State private var toastMessage: String?
    @State private var showRateSheet = false

    // V1.1.0：左右侧亮度 / 音量手势
    @StateObject private var volume = SystemVolumeController()
    @State private var brightness: Double = Double(UIScreen.main.brightness)
    @State private var activeSide: Side?
    @State private var dragStartValue: Double?

    // V2.2：控制层显示状态（默认显示，3 秒无操作自动隐藏）
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?

    private enum Side: Equatable {
        case brightness, volume

        var icon: String { self == .brightness ? "sun.max.fill" : "speaker.wave.2.fill" }
        var title: String { self == .brightness ? "亮度" : "音量" }
    }

    init(item: VideoItem) {
        _viewModel = StateObject(wrappedValue: PlayerViewModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoLayerView(
                player: viewModel.player,
                videoGravity: viewModel.isAspectFill ? .resizeAspectFill : .resizeAspect
            )
            .ignoresSafeArea()

            // V2.2：点画面切换控制层（显示时点一下隐藏，隐藏时点一下唤回）。
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.black.opacity(0.45), in: Circle())
                    .onTapGesture { viewModel.play() }
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
            }

            sideControls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            // 隐藏的系统音量控件（只用来读写系统音量；被视频画面盖住，不可见）
            SystemVolumeHost(controller: volume)
                .frame(width: 240, height: 44)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .statusBarHidden()
        .onAppear { scheduleAutoHide() }
        .onDisappear { autoHideTask?.cancel() }
        .onChange(of: showRateSheet) { isShowing in
            if isShowing {
                autoHideTask?.cancel()
            } else {
                scheduleAutoHide()
            }
        }
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "showRateSheet") { showRateSheet = true }
        }
        #endif
        .toast($toastMessage)
        .task {
            // V1.1.0：把同目录的视频注入队列，供列表循环 / 上一个下一个使用。
            viewModel.setQueue(library.videos(in: viewModel.item.folderID))
            await viewModel.reloadDuration()
            brightness = Double(UIScreen.main.brightness)
            await volume.refreshWhenReady()
        }
        .sheet(isPresented: $showRateSheet) {
            rateSheet
                .presentationDetents([.height(210)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $editorSource, onDismiss: {
            Task { await viewModel.reloadDuration() }
        }) { source in
            VideoEditorView(source: source)
                .environmentObject(library)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.pause()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(viewModel.item.source.displayName) · \(viewModel.item.fileSize.fileSizeText)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            // V2.2：右上角收敛成「⋯」更多菜单，后续扩展项都放这里。
            Menu {
                Button {
                    bumpActivity()
                    editorSource = .library(viewModel.item)
                } label: {
                    Label("剪辑", systemImage: "scissors")
                }

                Button {
                    bumpActivity()
                    viewModel.isAspectFill.toggle()
                } label: {
                    Label(
                        viewModel.isAspectFill ? "画面改为适应" : "画面改为填充",
                        systemImage: viewModel.isAspectFill
                            ? "rectangle.arrowtriangle.2.inward"
                            : "rectangle.arrowtriangle.2.outward"
                    )
                }

                Divider()

                Button {} label: {
                    Label("更多功能（预留）", systemImage: "sparkles")
                }
                .disabled(true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 底部控制

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(viewModel.currentTime.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(viewModel.duration.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }

            Slider(
                value: Binding(
                    get: { viewModel.currentTime },
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...max(viewModel.duration, 0.1)
            )
            .tint(Theme.accent)

            // V1.1.0：左侧循环模式 / 居中播放控制 / 右侧倍速，三段同排。
            ZStack {
                HStack {
                    loopMenu
                    Spacer()
                    speedButton
                }

                HStack(spacing: 14) {
                    transportButton(icon: "backward.end.fill", label: "上一个") {
                        viewModel.playPrevious()
                    }
                    transportButton(icon: "gobackward.10", label: "倒退 10 秒") {
                        viewModel.skip(by: -10)
                    }

                    Button {
                        viewModel.togglePlay()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Theme.accentGradient, in: Circle())
                    }
                    .accessibilityLabel(viewModel.isPlaying ? "暂停" : "播放")

                    transportButton(icon: "goforward.10", label: "前进 10 秒") {
                        viewModel.skip(by: 10)
                    }
                    transportButton(icon: "forward.end.fill", label: "下一个") {
                        viewModel.playNext()
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 控制层自动隐藏

    /// 每次操作都重置 3 秒计时；控制层隐藏时不重置（点一下才唤回）。
    private func bumpActivity() {
        guard controlsVisible else { return }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                controlsVisible = false
            }
        }
    }

    private func toggleControls() {
        if controlsVisible {
            autoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = false }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = true }
            scheduleAutoHide()
        }
    }

    // MARK: - 左右侧亮度 / 音量

    private var sideControls: some View {
        HStack(spacing: 0) {
            sideControl(.brightness)
            Spacer(minLength: 0)
            sideControl(.volume)
        }
        .padding(.horizontal, 10)
        .padding(.top, 92)
        .padding(.bottom, 154)
    }

    private func sideControl(_ side: Side) -> some View {
        let isActive = activeSide == side
        let value = side == .brightness
            ? brightness
            : (volume.isAvailable ? Double(volume.value) : Double(viewModel.playerVolume))
        return VStack(spacing: 8) {
            Image(systemName: side.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.35))

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(.white.opacity(isActive ? 0.18 : 0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentSecondary],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(height: max(3, geo.size.height * CGFloat(min(max(value, 0), 1))))
                }
                .overlay(
                    Capsule().stroke(.white.opacity(isActive ? 0.28 : 0.12), lineWidth: 1)
                )
            }
            .frame(width: 6)

            if isActive {
                Text("\(Int(value * 100))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 34, height: 210)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStartValue == nil {
                        dragStartValue = value
                        activeSide = side
                    }
                    let base = dragStartValue ?? value
                    let delta = Double(-drag.translation.height) / 190.0
                    applySideValue(base + delta, to: side)
                }
                .onEnded { _ in
                    dragStartValue = nil
                    let finished = side
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if activeSide == finished { activeSide = nil }
                    }
                }
        )
        .accessibilityLabel(side.title)
        .accessibilityValue("\(Int(value * 100))%")
    }

    private func applySideValue(_ raw: Double, to side: Side) {
        let clamped = min(max(raw, 0), 1)
        switch side {
        case .brightness:
            brightness = clamped
            UIScreen.main.brightness = CGFloat(clamped)
        case .volume:
            if volume.isAvailable {
                volume.set(Float(clamped))
            } else {
                viewModel.setVolume(Float(clamped))
            }
        }
    }

    private var loopMenu: some View {
        Menu {
            ForEach(PlaybackMode.allCases) { mode in
                Button {
                    viewModel.setMode(mode)
                } label: {
                    if viewModel.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            Image(systemName: viewModel.mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 30)
                .background(Capsule().fill(.white.opacity(0.1)))
        }
        .accessibilityLabel("循环模式：\(viewModel.mode.title)")
    }

    private var speedButton: some View {
        Button {
            showRateSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.rateLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(viewModel.rate == 1 ? .white.opacity(0.85) : Theme.accentSecondary)
            .frame(height: 30)
            .padding(.horizontal, 9)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .accessibilityLabel("播放速度 \(viewModel.rateLabel)")
    }

    private var rateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("播放速度")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(viewModel.rateLabel)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accentSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(viewModel.rate) },
                    set: { viewModel.setRate(Float($0)) }
                ),
                in: Double(PlayerViewModel.minRate)...Double(PlayerViewModel.maxRate),
                step: 0.05
            )
            .tint(Theme.accent)

            HStack {
                Text("0.25x")
                Spacer()
                Text("1x")
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("5x")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.92))
    }

    private func transportButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var emptyControl: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

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
    @State private var isLandscape = false
    @State private var showCastSheet = false
    @State private var showMoreMenu = false
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?

    // V2.4：锁定播放（只留解锁按钮可点）
    @State private var isLocked = false
    /// V2.5：锁模式下锁按钮 / 进度条也走 3 秒自动隐藏，点画面再次唤回。
    @State private var lockUIvisible = true

    private enum Side: Equatable {
        case brightness, volume

        var icon: String { self == .brightness ? "sun.max.fill" : "speaker.wave.2.fill" }
        var title: String { self == .brightness ? "亮度" : "音量" }
    }

    init(item: VideoItem) {
        _viewModel = StateObject(wrappedValue: PlayerViewModel(item: item))
        #if DEBUG
        // 截图钩子：直接以横屏布局进入播放页
        _isLandscape = State(initialValue: UserDefaults.standard.bool(forKey: "forceLandscape"))
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            if isLandscape {
                // V2.4：横屏播放 = 播放页整体旋转 90° 铺满横向画面，不改设备方向，
                // 其它页面仍是竖屏；再点一次按钮就回到竖屏布局。
                playerContent
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(90))
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                playerContent
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        // 生命周期挂在最外层：切横竖屏只是换布局分支，不能触发 onDisappear，
        // 否则会立刻把横屏状态清掉（表现为点一下横屏马上弹回竖屏）。
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
            if UserDefaults.standard.bool(forKey: "lockPlayer") { toggleLock() }
            if UserDefaults.standard.bool(forKey: "showCastSheet") { showCastSheet = true }
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
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .visible) {
            Button("剪辑") {
                bumpActivity()
                editorSource = .library(viewModel.item)
            }
            Button(viewModel.isAspectFill ? "画面改为适应" : "画面改为填充") {
                bumpActivity()
                viewModel.isAspectFill.toggle()
            }
            Button("投屏") {
                bumpActivity()
                showCastSheet = true
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showCastSheet) {
            castSheet
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
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

    private var playerContent: some View {
        ZStack {
            // 安全区统一由外层 GeometryReader 处理，子视图不再各自 ignoresSafeArea，
            // 否则横屏（整页旋转）时会被撑成竖屏尺寸。
            Color.black

            VideoLayerView(
                player: viewModel.player,
                videoGravity: viewModel.isAspectFill ? .resizeAspectFill : .resizeAspect
            )

            // V2.2：点画面切换控制层（显示时点一下隐藏，隐藏时点一下唤回）。
            // V2.4：锁定时屏幕触摸全部失效，只有解锁按钮可用。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isLocked { toggleLockUI() } else { toggleControls() }
                }

            if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.black.opacity(0.45), in: Circle())
                    .onTapGesture { viewModel.play() }
                    .opacity(controlsVisible && !isLocked ? 1 : 0)
                    .allowsHitTesting(controlsVisible && !isLocked)
            }

            sideControls
                .opacity(isLocked ? (lockUIvisible ? 1 : 0) : (controlsVisible ? 1 : 0))
                .allowsHitTesting(isLocked ? lockUIvisible : controlsVisible)

            // 隐藏的系统音量控件（只用来读写系统音量；被视频画面盖住，不可见）
            SystemVolumeHost(controller: volume)
                .frame(width: 240, height: 44)
                .opacity(0.01)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // V2.4：横屏播放时顶栏（返回 + 横屏退出）常驻，方便随时退出全屏；
                // 锁定时顶栏也一起隐藏。
                topBar
                    .opacity(topBarVisible ? 1 : 0)
                    .allowsHitTesting(topBarVisible)
                Spacer()
                bottomPanel
                    .opacity(isLocked ? (lockUIvisible ? 1 : 0) : (controlsVisible ? 1 : 0))
                    .allowsHitTesting(!isLocked && controlsVisible)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.easeInOut(duration: 0.22), value: lockUIvisible)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
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

            // V2.3：横屏播放按钮，放在「⋯」左边。
            Button {
                bumpActivity()
                toggleOrientation()
            } label: {
                Image(systemName: isLandscape ? "iphone" : "iphone.landscape")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel(isLandscape ? "退出横屏" : "横屏播放")

            // V2.2：右上角收敛成「⋯」更多，后续扩展项都放这里。
            // 用 Button + confirmationDialog 而不是 Menu：Menu 自带的 icon 内边距会让
            // 圆形按钮和左边的横屏按钮上下错位。
            Button {
                bumpActivity()
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
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
                    set: {
                        bumpActivity()
                        viewModel.seek(to: $0)
                    }
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
                        bumpActivity()
                        viewModel.playPrevious()
                    }
                    transportButton(icon: "gobackward.10", label: "倒退 10 秒") {
                        bumpActivity()
                        viewModel.skip(by: -10)
                    }

                    Button {
                        bumpActivity()
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
                        bumpActivity()
                        viewModel.skip(by: 10)
                    }
                    transportButton(icon: "forward.end.fill", label: "下一个") {
                        bumpActivity()
                        viewModel.playNext()
                    }
                }
            }
            .padding(.top, 2)
            // V2.5：锁模式下只保留进度条，运输控件（循环 / 播放键 / 倍速）整体隐藏。
            .opacity(isLocked ? 0 : 1)
            .allowsHitTesting(!isLocked)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 横屏 / 投屏

    private func toggleOrientation() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isLandscape.toggle()
        }
    }

    // MARK: - 控制层自动隐藏

    /// 每次操作都重置 3 秒计时；控制层隐藏时不重置（点一下才唤回）。
    private func bumpActivity() {
        guard controlsVisible, !isLocked else { return }
        scheduleAutoHide()
    }

    private var topBarVisible: Bool {
        !isLocked && (controlsVisible || isLandscape)
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

    /// V2.5：锁模式下只有锁按钮和进度条，3 秒无操作一起淡出。
    private func scheduleLockAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                lockUIvisible = false
            }
        }
    }

    private func toggleLockUI() {
        if lockUIvisible {
            autoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.22)) { lockUIvisible = false }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { lockUIvisible = true }
            scheduleLockAutoHide()
        }
    }

    private func toggleControls() {
        guard !isLocked else { return }
        if controlsVisible {
            autoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = false }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = true }
            scheduleAutoHide()
        }
    }

    // MARK: - 左右侧亮度 / 音量

    private var sliderHeight: CGFloat { isLandscape ? 96 : 210 }

    private var sideControls: some View {
        HStack(spacing: 0) {
            sideControl(.brightness)
                .opacity(isLocked ? 0 : 1)
                .allowsHitTesting(!isLocked)
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                sideControl(.volume)
                    .opacity(isLocked ? 0 : 1)
                    .allowsHitTesting(!isLocked)
                lockButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, isLandscape ? 64 : 92)
        // V2.5：锁按钮放大后整体下移，底部留白相应收窄，避免被底栏盖住。
        .padding(.bottom, isLandscape ? 176 : 184)
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
        .frame(width: 34, height: sliderHeight)
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
                    bumpActivity()
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

    /// V2.4：音量滑杆下方的锁按钮。锁定时图标变成开锁，且它是屏幕上唯一可点的元素。
    private var lockButton: some View {
        Button {
            toggleLock()
        } label: {
            Image(systemName: isLocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isLocked ? Theme.accent : .white.opacity(0.92))
                .frame(width: 48, height: 48)
                .background(.black.opacity(isLocked ? 0.55 : 0.38), in: Circle())
                .overlay(
                    Circle().stroke(
                        isLocked ? Theme.accent.opacity(0.85) : Color.white.opacity(0.28),
                        lineWidth: 1
                    )
                )
        }
        .accessibilityLabel(isLocked ? "解锁" : "锁定")
    }

    private func toggleLock() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isLocked.toggle()
        }
        if isLocked {
            activeSide = nil
            withAnimation(.easeInOut(duration: 0.22)) {
                controlsVisible = false
                lockUIvisible = true
            }
            toastMessage = "已锁定，点击锁图标解锁"
            scheduleLockAutoHide()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                controlsVisible = true
                lockUIvisible = true
            }
            scheduleAutoHide()
        }
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
                    bumpActivity()
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
            bumpActivity()
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

    private var castSheet: some View {
        VStack(spacing: 14) {
            Text("投屏")
                .font(.headline)
                .foregroundStyle(.white)

            AirPlayRoutePicker()
                .frame(width: 56, height: 56)

            Text("点上面的 AirPlay 按钮，选择电视或音箱；选中后播放会转到大屏，手机上的进度条依旧可以控制。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("完成") { showCastSheet = false }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accentSecondary)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.92))
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
                    set: {
                        viewModel.setRate(Float($0))
                    }
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

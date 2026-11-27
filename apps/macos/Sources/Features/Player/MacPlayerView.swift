import AVFoundation
import AppKit
import SwiftUI
import LeogotoPlayCore

// MARK: - 播放窗口（V3.1.1）

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
        // 让窗口接收 mouseMoved，否则 hover / 面板显隐在独立窗口里收不到事件
        window.acceptsMouseMovedEvents = true
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
    @State private var showSettings = false
    @State private var showPlaylist = false
    @State private var toast: String?

    /// 画面尺寸（素材原始尺寸，读取失败就按 16:9）
    @State private var videoSize = CGSize(width: 16, height: 9)
    /// 旋转角度（0/90/180/270）与左右上下翻转
    @State private var rotation = 0
    @State private var flipH = false
    @State private var flipV = false

    /// 控制面板：鼠标进出淡入淡出 + 自由拖动
    @State private var pointerInside = true
    @State private var panelOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero
    private let pointerTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    @State private var dragStartOffset: CGSize?
    @State private var dragStartPoint: CGPoint?
    private static let panelSize = CGSize(width: 520, height: 84)

    /// 全屏空闲自动隐藏：3 秒内无点击 / 无鼠标移动就把「操作面板 + 钉子」收起来
    @State private var isFullscreen = false
    @State private var controlsIdleHidden = false
    @State private var lastActivity = Date()
    @State private var lastPointerPoint = CGPoint(x: -1, y: -1)
    /// 指针是否已被我们藏起来（hide/unhide 必须成对，否则会漏到整个系统）
    @State private var cursorHidden = false
    private static let playerSpace = "playerSpace"

    /// 窗口置顶（「在最前」）
    @State private var isPinned = false
    @State private var pinHovering = false
    @State private var window: NSWindow?

    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    init(item: VideoItem) {
        _current = State(initialValue: item)
        _duration = State(initialValue: item.duration)
        _player = State(initialValue: AVPlayer(url: item.fileURL))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                videoCanvas

                // 单击播放/暂停，双击进入或退出全屏（面板、侧边栏盖在上层，不会被误触）
                MacPlayerClickCatcher(
                    onSingleClick: {
                        lastActivity = Date()
                        controlsIdleHidden = false
                        isPlaying ? pause() : play()
                    },
                    onDoubleClick: {
                        lastActivity = Date()
                        controlsIdleHidden = false
                        toggleFullscreen()
                    }
                )

                VStack(spacing: 0) {
                    // 全屏空闲时标题也跟着收起，模拟「只看画面」
                    titleBar
                        .opacity(isFullscreen && controlsIdleHidden ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: controlsIdleHidden)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                }

                controlPanelLayer(in: geo.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
                    .offset(panelOffset)

                if showPlaylist {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { showPlaylist = false }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        playlistSidebar
                            .transition(.move(edge: .trailing))
                    }
                    .animation(.easeInOut(duration: 0.22), value: showPlaylist)
                }

                if showSettings {
                    // 点空白处收起
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { showSettings = false }
                    settingsPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 26)
                        .padding(.bottom, 132)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                pinButton
                    .ignoresSafeArea(edges: .top)
            }
            .coordinateSpace(name: Self.playerSpace)
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
        }
        .ignoresSafeArea()
        .background(MacPlayerWindowReader { window = $0 })
        .onReceive(pointerTimer) { _ in pollPointer() }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: volume) { newValue in
            player.volume = Float(newValue)
        }
        .onChange(of: rate) { newValue in
            if isPlaying { player.rate = Float(newValue) }
        }
    }

    // MARK: - 画面

    /// 画面按素材原始比例缩放；旋转 90°/270° 时按旋转后的宽高来算，避免被裁掉
    private var videoCanvas: some View {
        GeometryReader { geo in
            let filled = filledVideoSize(in: geo.size)
            MacPlayerSurface(player: player)
                .frame(width: filled.width, height: filled.height)
                .rotationEffect(.degrees(Double(rotation)))
                .scaleEffect(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
    }

    private func filledVideoSize(in container: CGSize) -> CGSize {
        let source = videoSize.width > 0 && videoSize.height > 0
            ? videoSize
            : CGSize(width: 16, height: 9)
        let swapped = rotation == 90 || rotation == 270
        let visualWidth = swapped ? source.height : source.width
        let visualHeight = swapped ? source.width : source.height
        // 铺满窗口：取较大的缩放比例，多出来的部分裁掉，不再留上下黑边
        let scale = max(container.width / visualWidth, container.height / visualHeight)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    // MARK: - 顶部标题 + 置顶钉子

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
            // 钉子单独放在整窗顶部（见 pinButton），这里只留标题文字
            Color.clear.frame(width: 0, height: 0)
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// 右上角「在最前」钉子：贴窗口顶部 28pt 的标题条，垂直居中，上下留白一致
    private var pinButton: some View {
        HStack(spacing: 6) {
            if pinHovering && pinVisible {
                Text(isPinned ? "取消最前" : "在最前")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .fixedSize()
                    .transition(.opacity)
            }

            Button {
                isPinned.toggle()
                window?.level = isPinned ? .floating : .normal
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pinHovering || isPinned ? MacTheme.accent : Color.white.opacity(0.85))
                    .rotationEffect(.degrees(isPinned ? 0 : 90))
                    .animation(.easeInOut(duration: 0.28), value: isPinned)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
        .padding(.top, 7)
        .padding(.trailing, 10)
        .opacity(pinVisible ? 1 : 0)
        .allowsHitTesting(pinVisible)
        .animation(.easeInOut(duration: 0.2), value: pinVisible)
        .animation(.easeInOut(duration: 0.15), value: pinHovering)
    }

    // MARK: - 悬浮控制面板

    /// 面板显隐：鼠标在播放器区域就出现，移出窗口就消失（拖动中保持）
    private var showControls: Bool {
        if dragStartPoint != nil || dragStartOffset != nil { return true }
        return pointerInside && !controlsIdleHidden
    }

    /// 面板容器：鼠标进入整体淡入、离开整体淡出；面板底色可按住拖动，限制在窗口内
    private func controlPanelLayer(in size: CGSize) -> some View {
        ZStack {
            // 隐形命中层：面板淡出后仍然保留 hover 区域，鼠标回来能重新唤起
            Color.clear
                .frame(width: Self.panelSize.width, height: Self.panelSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.001))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .allowsHitTesting(showControls)

            controlPanel(in: size)
                .allowsHitTesting(showControls)
                .opacity(showControls ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: showControls)
    }

    /// 每 60ms 读一次鼠标位置：是否在播放器区域内，决定「操作面板 + 钉子」的显隐
    private func pollPointer() {
        guard let window, let content = window.contentView else { return }
        let bounds = content.bounds.size
        if containerSize != bounds { containerSize = bounds }
        // 屏幕坐标 → 窗口坐标 → 内容视图坐标，最后翻成「左上原点、y 朝下」
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inContent = content.convert(inWindow, from: nil)
        // SwiftUI 的宿主视图是 flipped 的，y 已经朝下，不能再翻
        let yDown = content.isFlipped ? inContent.y : bounds.height - inContent.y
        let point = CGPoint(x: inContent.x, y: yDown)
        let inside = point.x >= 0 && point.y >= 0
            && point.x <= bounds.width && point.y <= bounds.height

        // 全屏状态（窗口切换全屏有动画，靠轮询同步最快）
        let fullscreen = window.styleMask.contains(.fullScreen)
        if fullscreen != isFullscreen { isFullscreen = fullscreen }

        // 鼠标移动算「有活动」，静止就累计空闲时间
        if inside {
            let moved = hypot(point.x - lastPointerPoint.x, point.y - lastPointerPoint.y) > 1
            if moved || lastPointerPoint.x < 0 { lastActivity = Date() }
            lastPointerPoint = point
        } else {
            lastPointerPoint = CGPoint(x: -1, y: -1)
        }

        // 全屏时空闲满 3 秒就收起；非全屏或正在拖动则立刻恢复
        if isFullscreen, inside,
           dragStartPoint == nil, dragStartOffset == nil {
            let idle = Date().timeIntervalSince(lastActivity) >= 3
            if idle != controlsIdleHidden {
                withAnimation(.easeOut(duration: 0.2)) { controlsIdleHidden = idle }
            }
            setCursorHidden(idle)
        } else if controlsIdleHidden {
            controlsIdleHidden = false
        }

        setCursorHidden(isFullscreen && controlsIdleHidden)

        // 拖动过程中冻结 hover 轮询：每 60ms 改状态会打断 SwiftUI 的拖动手势
        if dragStartPoint != nil || dragStartOffset != nil {
            if inside != pointerInside { pointerInside = inside }
            return
        }
        if inside != pointerInside { setPointerInside(inside) }
        guard inside else {
            if pinHovering { withAnimation(.easeOut(duration: 0.15)) { pinHovering = false } }
            return
        }
        updatePinHover(at: point)
    }

    /// 钉子悬停（同样不依赖 SwiftUI hover）
    private func updatePinHover(at point: CGPoint) {
        guard pinVisible, containerSize.width > 0 else {
            if pinHovering { withAnimation(.easeOut(duration: 0.15)) { pinHovering = false } }
            return
        }
        let rect = CGRect(
            x: containerSize.width - 56,
            y: 4,
            width: 52,
            height: 44
        )
        let hovering = rect.contains(point)
        if hovering != pinHovering {
            withAnimation(.easeInOut(duration: 0.15)) { pinHovering = hovering }
        }
    }

    /// 全透明光标：比 NSCursor.hide() 稳，不受窗口光标重设影响，也不会漏到系统
    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// 藏 / 显鼠标指针：隐藏期间每轮询都重设一次（窗口一改光标就被顶回去）
    private func setCursorHidden(_ hidden: Bool) {
        if hidden == cursorHidden {
            if hidden { Self.invisibleCursor.set() }
            return
        }
        cursorHidden = hidden
        (hidden ? Self.invisibleCursor : NSCursor.arrow).set()
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        withAnimation(.easeOut(duration: 0.18)) { pointerInside = inside }
    }

    /// 面板拖动：只挂在底部圆角底色上，按钮 / 滑杆照常点击
    private func panelDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.playerSpace))
            .onChanged { drag in
                if dragStartPoint == nil {
                    dragStartPoint = drag.startLocation
                    dragStartOffset = panelOffset
                }
                guard let start = dragStartPoint, let base = dragStartOffset else { return }
                panelOffset = clampedPanelOffset(
                    CGSize(
                        width: base.width + (drag.location.x - start.x),
                        height: base.height + (drag.location.y - start.y)
                    ),
                    in: size
                )
            }
            .onEnded { _ in
                dragStartPoint = nil
                dragStartOffset = nil
            }
    }

    private func clampedPanelOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, (size.width - Self.panelSize.width) / 2 - 12)
        let maxUp = max(0, size.height - 28 - Self.panelSize.height - 12)
        let maxDown: CGFloat = 12
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxUp), maxDown)
        )
    }

    private func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func controlPanel(in size: CGSize) -> some View {
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
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showSettings ? MacTheme.accent : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("播放设置")

                Button {
                    showPlaylist.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showPlaylist ? MacTheme.accent : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("播放列表")
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
        .frame(width: Self.panelSize.width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.14).opacity(0.92))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .gesture(panelDragGesture(in: size))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .foregroundStyle(.white)
    }

    /// 钉子显隐：未置顶时常显；置顶（在最前）时鼠标进入播放器区域才出现
    private var pinVisible: Bool {
        showControls
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

    // MARK: - 设置面板（对齐参考稿：速度 / 循环 / 旋转）

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("速度")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f 倍", rate))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 4)

            Slider(value: $rate, in: 0.5...2.0)
                .tint(MacTheme.accent)
                .padding(.top, 10)

            HStack {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button {
                        rate = value
                    } label: {
                        Text(String(format: "%.1fx", value))
                            .font(.system(size: 12))
                            .foregroundStyle(rate == value ? Color.white : Color.white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 14)

            Divider().opacity(0.25)

            Toggle(isOn: $autoLoop) {
                Text("循环播放")
                    .font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.vertical, 12)

            Divider().opacity(0.25)

            Text("旋转")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 12)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                rotationButton("arrow.counterclockwise", tip: "向左旋转") { rotate(by: -90) }
                rotationButton("arrow.clockwise", tip: "向右旋转") { rotate(by: 90) }
                rotationButton("arrow.left.and.right", tip: "水平翻转", active: flipH) { flipH.toggle() }
                rotationButton("arrow.up.and.down", tip: "垂直翻转", active: flipV) { flipV.toggle() }
            }
            .padding(.bottom, 12)

            Divider().opacity(0.25)

            HStack {
                Spacer()
                Button {
                    resetTransform()
                } label: {
                    Text("重置")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
        .padding(15)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    private func rotationButton(_ symbol: String, tip: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? MacTheme.accent : .white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(active ? 0.16 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func rotate(by degrees: Int) {
        rotation = ((rotation + degrees) % 360 + 360) % 360
    }

    private func resetTransform() {
        rotation = 0
        flipH = false
        flipV = false
    }

    // MARK: - 播放列表

    /// 右侧侧边栏（从窗口右边缘滑出，占满高度）
    private var playlistSidebar: some View {
        let items = playlistItems
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("播放列表")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Button {
                    showPlaylist = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider().opacity(0.15)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { video in
                        Button {
                            if video.id != current.id { load(video) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: video.id == current.id ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(video.id == current.id ? MacTheme.accent : Color.white.opacity(0.4))
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(video.duration.timecode)
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(video.id == current.id ? Color.white.opacity(0.10) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.07))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }

    /// 当前视频所在文件夹里的全部视频，按创建时间倒序（= 列表里看到的顺序）
    private var playlistItems: [VideoItem] {
        let scope = library.videos(in: current.folderID)
        let list = scope.isEmpty ? library.videos(in: nil) : scope
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 播放控制

    /// 00:00:00 这种「时:分:秒」，和参考稿一致
    static func hms(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

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
        loadVideoSize()
        play()
    }

    private func loadVideoSize() {
        guard let asset = player.currentItem?.asset else { return }
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 16, height: 9)
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let applied = natural.applying(transform)
            let size = CGSize(width: abs(applied.width), height: abs(applied.height))
            await MainActor.run {
                if size.width > 0 && size.height > 0 {
                    videoSize = size
                    rotation = 0
                    flipH = false
                    flipV = false
                }
            }
        }
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
            } else if let next = adjacentVideo(offset: 1) {
                // 顺序播放：播完自动接当前文件夹里的下一条
                load(next)
            } else {
                isPlaying = false
            }
        }
    }

    private func stop() {
        player.pause()
        setCursorHidden(false)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func adjacentVideo(offset: Int) -> VideoItem? {
        let items = playlistItems
        guard !items.isEmpty,
              let index = items.firstIndex(where: { $0.id == current.id }) else { return nil }
        let target = index + offset
        guard items.indices.contains(target) else { return nil }
        return items[target]
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
        loadVideoSize()
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

// MARK: - 单击 / 双击捕获

/// 用一个 AppKit 视图区分单击与双击：单击播/暂停，双击全屏。
/// 单击动作延迟 0.25 秒执行，期间来了第二次点击就取消，避免双击顺带把播放切了两次。
private struct MacPlayerClickCatcher: NSViewRepresentable {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MacPlayerClickView {
        let view = MacPlayerClickView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: MacPlayerClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

final class MacPlayerClickView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingSingle: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingle?.cancel()
            pendingSingle = nil
            onDoubleClick?()
        } else {
            pendingSingle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onSingleClick?() }
            pendingSingle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

// MARK: - 拿窗口引用（置顶用）

private struct MacPlayerWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

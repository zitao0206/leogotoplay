import AppKit
import CoreGraphics
import SwiftUI

/// 剪映 / App 风格的时间轴（V2.7.6）：
/// - 刻度尺固定贴顶（挨着上方工具区），轨道在剩余空间居中后再整体上移 50pt，拖动条贴底；
/// - 播放指针从刻度尺顶贯穿到拖动条上沿；
/// - 缩略图全部为正方形（边长 = 轨道高度），一张图正好占「一个间隔」的宽度，胶片严丝合缝；
/// - 缩放由缩略图间隔驱动（默认 3.75s＝每分钟 16 张，放大分母 ×1.5，最小 1/30s，缩小 ×2，最稀 15s），
///   按钮走档位、捏合走连续，都以播放头为锚点；
/// - 编辑区可滑动时间轴：轨道上方的空白带支持鼠标拖拽平移，面板内任意位置的横向滚动 / 两指滑动也能平移。
struct MacTimelineView: View {
    let clips: [MacClip]
    /// 缩略图缓存：key = 槽位序号，覆盖时间 = 序号 × thumbnailInterval
    let frames: [Int: CGImage]
    /// 当前缩略图间隔（秒），由缩放档位决定
    let thumbnailInterval: Double
    let selectedIndex: Int?
    let outputDuration: Double
    let currentTime: Double
    let pixelsPerSecond: Double
    @Binding var scrollOffset: CGFloat
    let onSeek: (Double) -> Void
    /// 缩放（捏合手势），参数为新的缩略图间隔（已按区间夹好）
    let onSetThumbnailInterval: (Double) -> Void
    /// 上报可视宽度，供模型计算缩放下限
    let onViewportChange: (CGFloat) -> Void

    private let trackHeight: CGFloat = CGFloat(MacEditorModel.thumbnailSide)
    /// 缩放空间余量：内容放得下时两端各留的滑动距离（放不下时用满）
    static let sideInset: CGFloat = 100
    private let handleWidth: CGFloat = 8
    private let clipGap: CGFloat = 2
    private let rulerHeight: CGFloat = 26
    /// 底部拖动条区域总高（6 间距 + 10 条 + 2 底边距）
    private let bottomBarSpace: CGFloat = 18


    private var pps: CGFloat { CGFloat(pixelsPerSecond) }
    private var ppsD: Double { pixelsPerSecond }
    private var duration: Double { max(outputDuration, 0) }

    /// 内容轨道的净宽（不含两侧余量）
    private func trackWidth(pps: CGFloat) -> CGFloat {
        max(CGFloat(duration) * pps, 1)
    }

    /// 内容 x=0 的落点：放不下时留 sideInset 滑动余量；放得下时居中（两端不出大片空白）
    private func inset(for width: CGFloat, pps: CGFloat) -> CGFloat {
        let track = trackWidth(pps: pps)
        return track + Self.sideInset * 2 > width ? Self.sideInset : max((width - track) / 2, 8)
    }

    private func contentWidth(for width: CGFloat, pps: CGFloat) -> CGFloat {
        trackWidth(pps: pps) + inset(for: width, pps: pps) * 2
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let maxOffset = max(0, contentWidth(for: width, pps: pps) - width)
            let offset = min(max(0, scrollOffset), maxOffset)
            let ins = inset(for: width, pps: pps)

            // V2.7.5：刻度尺固定贴顶（挨着上方工具区），轨道在剩余空间居中后再整体上移 50pt，拖动条贴底
            let rulerTop: CGFloat = 4
            let available = max(geo.size.height - rulerTop - rulerHeight - bottomBarSpace, 0)
            let trackTopGap = max(6, (available - trackHeight - 8) / 2 - 50)

            // 可视窗口对应的时间范围，缩略图只渲染这段内的槽位
            let visibleStart = (Double(offset - ins) / ppsD)
            let visibleEnd = (Double(offset + width - ins) / ppsD)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler(width: width, offset: offset, inset: ins)
                        .frame(height: rulerHeight)
                        .padding(.top, rulerTop)
                        .contentShape(Rectangle())
                        .gesture(seekGesture(offset: offset, inset: ins))

                    // V2.7.6：轨道上方的空白带可以直接拖拽平移时间轴
                    Color.clear.frame(height: trackTopGap)
                        .contentShape(Rectangle())
                        .gesture(panGesture(offset: offset, maxOffset: maxOffset))
                        .onHover { inside in
                            if inside {
                                NSCursor.openHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

                    track(width: width, offset: offset, inset: ins,
                          visibleRange: visibleStart...visibleEnd)
                        .frame(height: trackHeight + 8)

                    // 轨道下方到拖动条之间的空白也能拖拽平移
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 6)
                        .contentShape(Rectangle())
                        .gesture(panGesture(offset: offset, maxOffset: maxOffset))
                        .onHover { inside in
                            if inside {
                                NSCursor.openHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

                    scrollBar(width: width, maxOffset: maxOffset, offset: offset)
                        .padding(.bottom, 2)
                }

                // 播放指针：顶部小圆帽 + 通长指针，从刻度尺顶贯穿到拖动条上沿
                playhead
                    .frame(height: max(geo.size.height - bottomBarSpace - rulerTop, 20), alignment: .top)
                    .offset(x: ins + CGFloat(currentTime) * pps - 5 - offset, y: rulerTop)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .gesture(
                // 捏合（触控板双指开合）连续缩放，锚点固定在播放指针
                MagnificationGesture()
                    .onChanged { value in
                        let base = magnifyBaseline ?? 1
                        let delta = Double(value / base)
                        magnifyBaseline = value
                        guard delta != 1 else { return }
                        applyZoom(multiplying: delta, width: width)
                    }
                    .onEnded { _ in magnifyBaseline = nil }
            )
            .background(
                // V2.7.6：面板内任意位置的横向滚动 / 两指滑动都能平移时间轴
                ScrollWheelPanReader { delta in
                    scrollOffset = min(max(0, offset - delta), maxOffset)
                }
            )
            .onAppear {
                onViewportChange(width)
                // 默认让片段起点贴着可视区左边，空白距离留出来给用户自己拖
                if scrollOffset == 0 {
                    scrollOffset = min(Self.sideInset, maxOffset)
                }
            }
            .onChange(of: geo.size.width) { newWidth in
                onViewportChange(newWidth)
            }
            .onChange(of: outputDuration) { _ in
                scrollOffset = min(Self.sideInset, maxOffset)
            }
        }
    }

    @State private var magnifyBaseline: CGFloat?
    @State private var panBaseline: CGFloat?

    // MARK: - 缩放

    /// 以播放指针为锚点缩放：指针在屏上的位置保持不动
    private func applyZoom(multiplying factor: Double, width: CGFloat) {
        guard factor > 0, factor.isFinite else { return }
        // 放大 = 间隔变小（分母 ×1.5）；缩小 = 间隔变大（×2）；下限 1/30s，上限由模型按 t/4 夹住
        let newInterval = max(thumbnailInterval / factor, MacEditorModel.minThumbnailInterval)
        guard abs(newInterval - thumbnailInterval) > 1e-9 else { return }

        let anchorTime = currentTime
        let ins = inset(for: width, pps: pps)
        let anchorX = ins + CGFloat(anchorTime) * pps
            - min(max(0, scrollOffset), max(0, contentWidth(for: width, pps: pps) - width))

        let newPPS = MacEditorModel.thumbnailSide / newInterval
        let newTrack = CGFloat(duration) * CGFloat(newPPS)
        let newIns = newTrack + Self.sideInset * 2 > width ? Self.sideInset : max((width - newTrack) / 2, 8)
        let newMaxOffset = max(0, newTrack + newIns * 2 - width)

        scrollOffset = min(max(0, newIns + CGFloat(anchorTime) * CGFloat(newPPS) - anchorX), newMaxOffset)
        onSetThumbnailInterval(newInterval)
    }

    // MARK: - 时间刻度尺

    /// 主刻度间隔：按「间距 ≈ 80pt」自动挑一档（0.1s ~ 1h）
    private func majorTickInterval(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = 80 / Double(pps)
        return candidates.first { $0 >= target } ?? 3600
    }

    /// 拖拽平移：按下时记住起点 offset，拖动时按位移反向推内容
    private func panGesture(offset: CGFloat, maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if panBaseline == nil {
                    panBaseline = offset
                }
                let base = panBaseline ?? offset
                scrollOffset = min(max(0, base - value.translation.width), maxOffset)
            }
            .onEnded { _ in panBaseline = nil }
    }

    private func seekGesture(offset: CGFloat, inset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSeek(Double(max(0, value.location.x + offset - inset)) / pixelsPerSecond)
            }
    }

    private func ruler(width: CGFloat, offset: CGFloat, inset ins: CGFloat) -> some View {
        Canvas { ctx, size in
            let interval = majorTickInterval(pps: pps)
            let minorStep = interval / 5

            // 只画可视窗口内的刻度（时间轴可能宽达几十万 pt）
            let startT = max(0, ((Double(offset - ins) / ppsD) / interval).rounded(.down) * interval)
            let endT = (Double(offset + width - ins) / ppsD) + interval

            var t = startT
            while t <= endT {
                let x = ins + CGFloat(t) * pps - offset
                let time = t

                if time > 0.0001 && time <= duration {
                    // 次刻度（主刻度五等分）
                    for i in 1..<5 {
                        let minorTime = time + Double(i) * minorStep
                        guard minorTime <= duration else { continue }
                        let mx = x + CGFloat(Double(i) * minorStep) * pps
                        var minor = Path()
                        minor.move(to: CGPoint(x: mx, y: size.height))
                        minor.addLine(to: CGPoint(x: mx, y: size.height - 5))
                        ctx.stroke(minor, with: .color(.white.opacity(0.22)), lineWidth: 1)
                    }
                }

                if time <= duration + 0.0001 {
                    // 主刻度 + 时间标签
                    var major = Path()
                    major.move(to: CGPoint(x: x, y: size.height))
                    major.addLine(to: CGPoint(x: x, y: size.height - 10))
                    ctx.stroke(major, with: .color(.white.opacity(0.45)), lineWidth: 1)

                    let label = Text(time.timecode)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
                    ctx.draw(label, at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
                }

                t += interval
            }
        }
    }

    // MARK: - 轨道

    private func track(width: CGFloat, offset: CGFloat, inset ins: CGFloat, visibleRange: ClosedRange<Double>) -> some View {
        clipRow(visibleRange: visibleRange)
            .padding(.top, 8)
            .offset(x: ins - offset)
            .frame(width: width, height: trackHeight + 8, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(seekGesture(offset: offset, inset: ins))
    }

    private func clipRow(visibleRange: ClosedRange<Double>) -> some View {
        let starts = timelineStarts()
        return HStack(spacing: clipGap) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                clipBlock(clip, index: index, timelineStart: starts[index], visibleRange: visibleRange)
            }
        }
        .frame(height: trackHeight, alignment: .topLeading)
    }

    /// 每个片段在时间轴上的起点（按先后顺次累加时长；素材入点 clip.start 只用于取帧）
    private func timelineStarts() -> [Double] {
        var out: [Double] = []
        var cursor = 0.0
        for clip in clips {
            out.append(cursor)
            cursor += clip.duration
        }
        return out
    }

    private func clipBlock(_ clip: MacClip, index: Int, timelineStart: Double, visibleRange: ClosedRange<Double>) -> some View {
        let width = max(CGFloat(clip.duration) * pps, 6)
        let selected = index == selectedIndex
        let drawWidth = max(width - (index == 0 ? 0 : clipGap / 2), 4)

        return ZStack(alignment: .topLeading) {
            filmstrip(for: clip, timelineStart: timelineStart, visibleRange: visibleRange)
                .frame(width: drawWidth, height: trackHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // 未选中：细白框；选中：白色粗框（和 App 的选中框一致）
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    selected ? Color.white : Color.white.opacity(0.18),
                    lineWidth: selected ? 3 : 1
                )

            if selected {
                handle(roundedOnLeft: true)
                    .offset(x: 0, y: 0)
                handle(roundedOnLeft: false)
                    .offset(x: drawWidth - handleWidth, y: 0)
            }

            if drawWidth > 64 {
                Text("片段 \(index + 1) · \(clip.duration.timecode)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .padding(.leading, selected ? handleWidth + 6 : 7)
                    .padding(.top, 5)
            }
        }
        .frame(width: drawWidth, height: trackHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 选中段的夹持把手：白色圆角块 + 中间一根深色竖条（与 iOS 端同款）
    private func handle(roundedOnLeft: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: roundedOnLeft ? 6 : 0,
            bottomLeadingRadius: roundedOnLeft ? 6 : 0,
            bottomTrailingRadius: roundedOnLeft ? 0 : 6,
            topTrailingRadius: roundedOnLeft ? 0 : 6,
            style: .continuous
        )
        .fill(Color.white)
        .frame(width: handleWidth, height: trackHeight)
        .overlay(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .frame(width: 4, height: 32)
        )
    }

    // MARK: - 逐帧胶片（V2.7.4：密度随缩放档位，只渲染可视窗口；V2.7.5：缩略图为正方形）

    /// 缩略图按「每 thumbnailInterval 秒一张」取帧，槽位 k 覆盖 [k·interval, (k+1)·interval)。
    /// V2.7.5：每张缩略图固定为 trackHeight × trackHeight 的正方形，从左到右连续铺满轨道；
    /// 高倍缩放时全片可达数千槽位，这里只建可视窗口交集中的那几十个视图。
    private func filmstrip(for clip: MacClip, timelineStart: Double, visibleRange: ClosedRange<Double>) -> some View {
        let interval = max(thumbnailInterval, 1.0 / 30)
        // 槽位 key 用素材时间（slot × interval），可视窗口是时间轴时间，两者差 clip.start - timelineStart
        let firstSlot = Int(floor(clip.start / interval))
        let lastSlot = max(Int(ceil(clip.end / interval)), firstSlot + 1)

        let assetVisibleStart = clip.start + max(0, visibleRange.lowerBound - timelineStart)
        let assetVisibleEnd = min(clip.end, clip.start + max(0, visibleRange.upperBound - timelineStart))
        let renderFirst = max(firstSlot, Int(floor(assetVisibleStart / interval)))
        let renderLast = min(lastSlot, max(Int(ceil(assetVisibleEnd / interval)), renderFirst + 1))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))

            if renderLast > renderFirst {
                HStack(spacing: 0) {
                    ForEach(renderFirst..<renderLast, id: \.self) { slot in
                        ZStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.10))
                            if let image = frames[slot] {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: trackHeight, height: trackHeight)
                        .clipped()
                    }
                }
                .offset(x: CGFloat(Double(renderFirst) * interval - clip.start) * pps)
            }
        }
        .clipped()
    }

    // MARK: - 横向滑杆

    private func scrollBar(width: CGFloat, maxOffset: CGFloat, offset: CGFloat) -> some View {
        let content = contentWidth(for: width, pps: pps)
        let visibleRatio = content > 0 ? min(1, width / content) : 1
        let thumbWidth = max(44, width * visibleRatio)
        let travel = max(width - thumbWidth, 1)
        let ratio = maxOffset > 0 ? min(max(offset / maxOffset, 0), 1) : 0

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.10))
                .frame(height: 8)

            Capsule()
                .fill(Color.white.opacity(0.42))
                .frame(width: thumbWidth, height: 8)
                .offset(x: travel * ratio)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let location = min(max(0, value.location.x - thumbWidth / 2), travel)
                            scrollOffset = (location / travel) * maxOffset
                        }
                )
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 播放指针

    /// 顶部小圆帽 + 通长指针，从刻度尺顶贯穿到拖动条上沿
    private var playhead: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: 10, height: 7)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
        .allowsHitTesting(false)
    }
}

// MARK: - 横向滚动平移（V2.7.6）

/// 装一个「命中测试返回 nil」的透明 NSView 做本地事件监听：
/// 不抢点击（时间轴的点选 / 拖拽照旧），只在光标落在时间轴面板内时消费横向滚动，
/// 把触控板两指左右滑、鼠标左右滚、Shift + 竖滚 都换算成时间轴的横向平移。
private struct ScrollWheelPanReader: NSViewRepresentable {
    let onPan: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        PanCatcher(onPan: onPan)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PanCatcher)?.onPan = onPan
    }

    final class PanCatcher: NSView {
        var onPan: (CGFloat) -> Void
        private var monitor: Any?

        init(onPan: @escaping (CGFloat) -> Void) {
            self.onPan = onPan
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return event }

                    var delta = event.scrollingDeltaX
                    if abs(delta) < 0.5, event.modifierFlags.contains(.shift) {
                        delta = event.scrollingDeltaY
                    }
                    guard abs(delta) > 0.5 else { return event }
                    self.onPan(delta)
                    return nil
                }
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

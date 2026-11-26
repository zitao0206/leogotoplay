import CoreGraphics
import SwiftUI

/// 剪映 / App 风格的时间轴（V2.7.2）：
/// - 顶部一条时间刻度尺（主刻度带 mm:ss 标签，次刻度细分），跟随内容横向滚动；
/// - 播放指针从刻度尺顶一直贯到下方拖动条；
/// - 缩放：按钮档位式步进（×1.3），捏合手势连续缩放，共用同一区间——
///   下限 = 整条内容刚好铺满可视宽度（两端不出大片空白），上限 ≈ 25pt/帧（按 30fps）。
struct MacTimelineView: View {
    let clips: [MacClip]
    let frames: [CGImage?]
    let selectedIndex: Int?
    let outputDuration: Double
    let currentTime: Double
    let pixelsPerSecond: Double
    @Binding var scrollOffset: CGFloat
    let onSeek: (Double) -> Void
    /// V2.7.2：连续缩放（捏合手势），参数为新的每秒像素值（视图已按区间夹好）
    let onZoom: (Double) -> Void
    /// V2.7.2：上报可视宽度，供模型计算缩放下限
    let onViewportChange: (CGFloat) -> Void

    private let trackHeight: CGFloat = 87
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

    /// 缩放上限：约 25pt/帧（按 30fps ≈ 750pt/秒），正好能逐帧点选、看清帧边界
    static let maxPixelsPerSecond: Double = 750

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

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // V2.7.2：时间刻度尺
                    ruler(width: width, offset: offset, inset: ins)
                        .frame(height: rulerHeight)
                        .contentShape(Rectangle())
                        .gesture(seekGesture(offset: offset, inset: ins))

                    track(width: width, offset: offset, inset: ins)
                        .frame(height: trackHeight + 8)

                    Spacer(minLength: 6)

                    scrollBar(width: width, maxOffset: maxOffset, offset: offset)
                        .padding(.bottom, 2)
                }

                // V2.7.2：播放指针加长——上顶刻度尺、下触拖动条
                playhead
                    .frame(height: max(geo.size.height - bottomBarSpace, 20), alignment: .top)
                    .offset(x: ins + CGFloat(currentTime) * pps - 5 - offset, y: 0)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .gesture(
                // V2.7.2：捏合（触控板双指开合）连续缩放，锚点固定在播放指针
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
            .onAppear {
                onViewportChange(width)
                // 默认让片段起点贴着可视区左边，空白距离留出来给用户自己拖
                if scrollOffset == 0 {
                    scrollOffset = min(Self.sideInset, maxOffset)
                }
            }
            .onChange(of: geo.size.width) { newWidth in
                onViewportChange(newWidth)
                // 窗口拉大后内容可能已满足“铺满”下限，把缩放夹回区间内
                let minPPS = Double(newWidth) / max(duration, 0.1)
                if ppsD < minPPS {
                    applyZoom(multiplying: minPPS / ppsD, width: newWidth)
                }
            }
            .onChange(of: outputDuration) { _ in
                scrollOffset = min(Self.sideInset, maxOffset)
            }
        }
    }

    @State private var magnifyBaseline: CGFloat?

    // MARK: - 缩放

    /// 以播放指针为锚点缩放：指针在屏上的位置保持不动
    private func applyZoom(multiplying factor: Double, width: CGFloat) {
        let anchorTime = currentTime
        let ins = inset(for: width, pps: pps)
        let anchorX = ins + CGFloat(anchorTime) * pps - min(max(0, scrollOffset), max(0, contentWidth(for: width, pps: pps) - width))

        let minPPS = Double(width) / max(duration, 0.1)
        let newPPS = min(max(ppsD * factor, minPPS), Self.maxPixelsPerSecond)
        let newTrack = CGFloat(duration) * CGFloat(newPPS)
        let newIns = newTrack + Self.sideInset * 2 > width ? Self.sideInset : max((width - newTrack) / 2, 8)
        let newMaxOffset = max(0, newTrack + newIns * 2 - width)

        scrollOffset = min(max(0, newIns + CGFloat(anchorTime) * CGFloat(newPPS) - anchorX), newMaxOffset)
        onZoom(newPPS)
    }

    // MARK: - 时间刻度尺

    /// 主刻度间隔：按「间距 ≈ 80pt」自动挑一档（0.1s ~ 1h）
    private func majorTickInterval(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = 80 / Double(pps)
        return candidates.first { $0 >= target } ?? 3600
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
            let ppsD = ppsD

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

    private func track(width: CGFloat, offset: CGFloat, inset ins: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            clipRow
                .padding(.top, 8)
                .offset(x: ins - offset)

            // 旧版短指针已由整条播放指针取代，这里只保留选中框等内容
        }
        .frame(width: width, height: trackHeight + 8, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(seekGesture(offset: offset, inset: ins))
    }

    private var clipRow: some View {
        HStack(spacing: clipGap) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                clipBlock(clip, index: index)
            }
        }
        .frame(height: trackHeight, alignment: .topLeading)
    }

    private func clipBlock(_ clip: MacClip, index: Int) -> some View {
        let width = max(CGFloat(clip.duration) * pps, 6)
        let selected = index == selectedIndex
        let drawWidth = max(width - (index == 0 ? 0 : clipGap / 2), 4)

        return ZStack(alignment: .topLeading) {
            filmstrip(for: clip)
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

    // MARK: - 逐帧胶片

    /// 胶片按「源视频每秒一帧」铺，起点是 floor(clip.start)，用负偏移把半秒误差对齐
    private func filmstrip(for clip: MacClip) -> some View {
        let startIndex = Int(floor(clip.start))
        let endIndex = max(Int(ceil(clip.end)), startIndex + 1)
        let offset = CGFloat(clip.start - Double(startIndex)) * pps

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                ForEach(startIndex..<endIndex, id: \.self) { second in
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                        if second >= 0, second < frames.count, let image = frames[second] {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: pps, height: trackHeight)
                    .clipped()
                }
            }
            .offset(x: -offset)
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

    /// V2.7.2：顶部小圆帽 + 通长指针，从刻度尺顶贯穿到拖动条上沿
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

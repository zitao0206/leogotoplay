import CoreGraphics
import SwiftUI

/// 剪映 / App 风格的时间轴（V2.6）：每段铺满逐帧缩略图、播放头所在的段落带白色选中框，
/// 下面跟一条横向滑杆，可以拖动查看时间轴两端。
struct MacTimelineView: View {
    let clips: [MacClip]
    let frames: [CGImage?]
    let selectedIndex: Int?
    let outputDuration: Double
    let currentTime: Double
    let pixelsPerSecond: Double
    @Binding var scrollOffset: CGFloat
    let onSeek: (Double) -> Void

    private let trackHeight: CGFloat = 87
    /// 时间轴两端各留 100pt 的空白滑动距离（合计 200pt），拖到头还能再滑一段
    private let sideInset: CGFloat = 100
    private let handleWidth: CGFloat = 8
    private let clipGap: CGFloat = 2

    private var contentWidth: CGFloat {
        max(CGFloat(outputDuration) * CGFloat(pixelsPerSecond), 1) + sideInset * 2
    }
    private var pps: CGFloat { CGFloat(pixelsPerSecond) }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let maxOffset = max(0, contentWidth - width)
            let offset = min(max(0, scrollOffset), maxOffset)

            // V2.7：轨道在编辑区竖直居中，滑杆贴在最底部
            VStack(spacing: 0) {
                Spacer(minLength: 6)
                track(width: width, offset: offset)
                Spacer(minLength: 6)
                scrollBar(width: width, maxOffset: maxOffset, offset: offset)
                    .padding(.bottom, 2)
            }
            .onAppear {
                // 默认让片段起点贴着可视区左边，空白距离留出来给用户自己拖
                if scrollOffset == 0 {
                    scrollOffset = min(sideInset, maxOffset)
                }
            }
            .onChange(of: outputDuration) { _ in
                scrollOffset = min(sideInset, maxOffset)
            }
        }
    }

    // MARK: - 轨道

    private func track(width: CGFloat, offset: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            clipRow
                .padding(.top, 20)
                .offset(x: sideInset - offset)

            playhead
                .offset(x: sideInset + CGFloat(currentTime) * pps - 4 - offset, y: 0)
        }
        .frame(width: width, height: trackHeight + 20, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSeek(Double(max(0, value.location.x + offset - sideInset)) / pixelsPerSecond)
                }
        )
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
        let visibleRatio = contentWidth > 0 ? min(1, width / contentWidth) : 1
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

    // MARK: - 播放头

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .padding(.top, 2)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: trackHeight + 10)
        }
        .allowsHitTesting(false)
    }
}

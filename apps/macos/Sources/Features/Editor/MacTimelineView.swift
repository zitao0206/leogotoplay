import CoreGraphics
import SwiftUI

/// 剪映 / App 风格的时间轴（V2.4）：每段铺满源视频的逐帧缩略图，播放头所在的段落带白色选中框和两个夹持把手。
struct MacTimelineView: View {
    let clips: [MacClip]
    let frames: [CGImage?]
    let selectedIndex: Int?
    let outputDuration: Double
    let currentTime: Double
    let pixelsPerSecond: Double
    let onSeek: (Double) -> Void

    private let trackHeight: CGFloat = 58
    private let handleWidth: CGFloat = 8
    private let clipGap: CGFloat = 2

    private var contentWidth: CGFloat { max(CGFloat(outputDuration) * CGFloat(pixelsPerSecond), 1) }
    private var pps: CGFloat { CGFloat(pixelsPerSecond) }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    clipRow
                        .padding(.top, 16)

                    playhead
                }
                .frame(
                    width: max(contentWidth, geo.size.width),
                    height: max(geo.size.height, 1),
                    alignment: .topLeading
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onSeek(Double(max(0, value.location.x)) / pixelsPerSecond)
                        }
                )
            }
        }
    }

    // MARK: - 片段行

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
                .frame(width: 3, height: 22)
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
        .offset(x: CGFloat(currentTime) * pps - 4, y: 0)
        .allowsHitTesting(false)
    }
}

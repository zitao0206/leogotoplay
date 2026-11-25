import SwiftUI

/// 剪映风格的时间轴：片段块按时间宽度铺开，播放头可点可拖。
struct MacTimelineView: View {
    let clips: [MacClip]
    let outputDuration: Double
    let currentTime: Double
    let pixelsPerSecond: Double
    let onSeek: (Double) -> Void

    private var contentWidth: CGFloat { max(CGFloat(outputDuration) * CGFloat(pixelsPerSecond), 1) }

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

    private var clipRow: some View {
        HStack(spacing: 2) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                clipBlock(clip, index: index)
            }
        }
        .frame(height: 60, alignment: .top)
    }

    private func clipBlock(_ clip: MacClip, index: Int) -> some View {
        let width = max(CGFloat(clip.duration) * CGFloat(pixelsPerSecond), 4)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MacTheme.accent.opacity(0.75), MacTheme.accent.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)

            if width > 46 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("片段 \(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(clip.duration.timecode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.top, 8)
            }
        }
        .frame(width: width, height: 58)
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .padding(.top, 2)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 68)
        }
        .offset(x: CGFloat(currentTime) * CGFloat(pixelsPerSecond) - 4, y: 0)
        .allowsHitTesting(false)
    }
}

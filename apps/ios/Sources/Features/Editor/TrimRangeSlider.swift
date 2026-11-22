import SwiftUI
import LeogotoPlayCore

/// 剪辑时间轴：胶片帧 + 左右可拖动的裁剪手柄。
struct TrimRangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    var frames: [UIImage] = []
    var onChange: ((Double, Double) -> Void)? = nil

    @State private var leftDragOrigin: CGFloat?
    @State private var rightDragOrigin: CGFloat?

    private let trackHeight: CGFloat = 52
    private let handleWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let safeDuration = max(duration, 0.01)
            let startX = CGFloat(start / safeDuration) * width
            let endX = CGFloat(end / safeDuration) * width
            let minGap = min(0.2, max(0.05, duration * 0.01))

            ZStack(alignment: .topLeading) {
                filmstrip(width: width)

                // 未选中区域压暗
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: max(0, startX), height: trackHeight)
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: max(0, width - endX), height: trackHeight)
                    .offset(x: endX)

                // 选中框
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(width: max(4, endX - startX), height: trackHeight)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                // 左手柄
                handle
                    .frame(width: handleWidth, height: trackHeight)
                    .offset(x: max(0, startX - handleWidth / 2))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if leftDragOrigin == nil { leftDragOrigin = startX }
                                let origin = leftDragOrigin ?? startX
                                let newX = min(max(0, origin + value.translation.width), width)
                                let seconds = Double(newX / width) * safeDuration
                                start = min(max(0, seconds), max(0, end - minGap))
                                onChange?(start, end)
                            }
                            .onEnded { _ in leftDragOrigin = nil }
                    )

                // 右手柄
                handle
                    .frame(width: handleWidth, height: trackHeight)
                    .offset(x: min(width - handleWidth, max(0, endX - handleWidth / 2)))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if rightDragOrigin == nil { rightDragOrigin = endX }
                                let origin = rightDragOrigin ?? endX
                                let newX = min(max(0, origin + value.translation.width), width)
                                let seconds = Double(newX / width) * safeDuration
                                end = max(min(safeDuration, seconds), min(safeDuration, start + minGap))
                                onChange?(start, end)
                            }
                            .onEnded { _ in rightDragOrigin = nil }
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: trackHeight)
    }

    private var handle: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: 18)
                )
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        ZStack {
            if frames.isEmpty {
                Rectangle().fill(Color.white.opacity(0.12))
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width / CGFloat(max(frames.count, 1)), height: trackHeight)
                            .clipped()
                    }
                }
                .frame(width: width, height: trackHeight, alignment: .leading)
            }
        }
        .frame(width: width, height: trackHeight)
    }
}

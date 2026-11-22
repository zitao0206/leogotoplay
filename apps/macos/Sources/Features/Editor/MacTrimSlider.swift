import AppKit
import SwiftUI

/// 胶片条 + 双柄裁剪滑块（macOS 版，等价于 iOS 的 TrimRangeSlider）。
struct MacTrimSlider: View {
    var filmstrip: [NSImage] = []
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let currentTime: Double
    var onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 14
    private let trackHeight: CGFloat = 48

    private var lowerRatio: CGFloat { duration > 0 ? CGFloat(start / duration) : 0 }
    private var upperRatio: CGFloat { duration > 0 ? CGFloat(end / duration) : 1 }
    private var playRatio: CGFloat { duration > 0 ? CGFloat(min(max(currentTime, 0), duration) / duration) : 0 }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)

            ZStack(alignment: .leading) {
                // 胶片条背景
                HStack(spacing: 0) {
                    if filmstrip.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.06))
                    } else {
                        ForEach(Array(filmstrip.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: max(geo.size.width / CGFloat(max(filmstrip.count, 1)) + 1, 1),
                                       height: trackHeight)
                                .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 选中区间
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: max(0, (upperRatio - lowerRatio) * width))
                    .offset(x: lowerRatio * width)
                    .overlay(
                        Rectangle()
                            .stroke(MacTheme.accent, lineWidth: 2)
                            .frame(width: max(0, (upperRatio - lowerRatio) * width))
                            .offset(x: lowerRatio * width),
                        alignment: .leading
                    )

                // 区间外压暗
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .frame(width: max(0, lowerRatio * width))
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .frame(width: max(0, (1 - upperRatio) * width))
                    .offset(x: upperRatio * width)

                // 播放头
                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5)
                    .offset(x: min(max(playRatio * width, 0), width - 1.5))

                handle(ratio: lowerRatio, width: width, isLeft: true)
                handle(ratio: upperRatio, width: width, isLeft: false)
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / width, 0), 1)
                        onScrub(ratio * duration)
                    }
            )
        }
        .frame(height: trackHeight)
    }

    private func handle(ratio: CGFloat, width: CGFloat, isLeft: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(MacTheme.accent)
            .frame(width: handleWidth, height: trackHeight + 8)
            .overlay(
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: 16)
            )
            .offset(x: min(max(ratio * width - handleWidth / 2, 0), width - handleWidth))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let seconds = Double((ratio * width + value.translation.width) / width) * duration
                        if isLeft {
                            start = min(max(0, seconds), max(0, end - 0.05))
                        } else {
                            end = max(min(duration, seconds), min(duration, start + 0.05))
                        }
                    }
            )
            .onTapGesture {
                onScrub(isLeft ? start : end)
            }
    }
}

import SwiftUI
import LeogotoPlayCore

/// 剪辑时间轴：按「成片时间」铺的胶片条 + 分段框 + 固定播放头。
///
/// 交互仿剪映：白色播放头固定在时间轴正中不动，胶片条在下面横向滑动，
/// 滑到最左 / 最右时还有约半个屏幕的富余距离（左右各半屏 ≈ 一屏总行程）。
/// 删掉的片段不再占位置，剩下的片段首尾相接，段间留 2pt 黑缝。
struct EditTimelineView: View {
    let frames: [UIImage?]
    /// 成片总时长（已算进倍速、已去掉被删的片段）
    let outputDuration: Double
    let clips: [EditorViewModel.Clip]
    let selectedClipID: UUID?
    /// 播放头（成片时间）：始终对齐到时间轴正中
    let playhead: Double
    var onScrub: (Double) -> Void
    var onSelect: (UUID?) -> Void

    /// 播放头位置对应的成片时间（胶片条按它平移）
    @State private var scrollTime: Double = 0
    @State private var isDragging = false
    @State private var dragStartTime: Double = 0

    private let trackHeight: CGFloat = 64
    private let clipGap: CGFloat = 2
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let total = max(outputDuration, 0.01)
            let time = min(max(scrollTime, 0), total)
            // 成片时间 0 落在正中，往后每一屏扫过一个 width，左右各留半屏余量
            let stripX = width / 2 - CGFloat(time / total) * width

            ZStack(alignment: .topLeading) {
                content(width: width, total: total, stripX: stripX)

                // 固定播放头
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: trackHeight + 6)
                    .offset(x: width / 2 - 1, y: -3)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartTime = time
                        }
                        let moved = dragStartTime - Double(value.translation.width) / Double(width) * total
                        let target = min(max(moved, 0), total)
                        if abs(target - scrollTime) > 0.0005 {
                            scrollTime = target
                            onScrub(target)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        let moved = abs(Double(value.translation.width))
                        if moved < 6 {
                            // 轻点：把被点的时间送到播放头位置（时间轴跟着走一格）
                            let tapped = clamp(timeAt(x: value.location.x, width: width, total: total), total: total)
                            scrollTime = tapped
                            onScrub(tapped)
                            onSelect(clipID(at: tapped))
                        } else {
                            // 拖动：保持松手时的位置，不重新对齐（否则会弹回拖动起点）
                            let settled = clamp(scrollTime, total: total)
                            scrollTime = settled
                            onScrub(settled)
                            onSelect(clipID(at: settled))
                        }
                    }
            )
            .onAppear {
                scrollTime = min(max(playhead, 0), total)
            }
            .onChange(of: playhead) { newValue in
                // 播放 / 外部 seek 时胶片条跟着走；手指拖动时不抢
                guard !isDragging else { return }
                scrollTime = min(max(newValue, 0), total)
            }
            .onChange(of: outputDuration) { _ in
                scrollTime = min(max(scrollTime, 0), max(outputDuration, 0.01))
            }
        }
        .frame(height: trackHeight)
    }

    // MARK: - 内容（胶片 + 分段 + 把手）

    @MainActor
    @ViewBuilder
    private func content(width: CGFloat, total: Double, stripX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 空轨道底色：胶片滑出去的空白处不会显得像被截断
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: width, height: trackHeight)

            filmstrip(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .offset(x: stripX)

            ForEach(layout(width: width, total: total)) { block in
                let isSelected = block.id == selectedClipID

                // 段与段之间留约 2pt 的缝（宽度接近进度指针），缝里是纯黑，一眼看出是两段
                if block.index > 0 {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: clipGap, height: trackHeight)
                        .offset(x: stripX + block.x - clipGap / 2, y: 0)
                        .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.05) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.white : Color.white.opacity(0.18),
                                lineWidth: isSelected ? 3.5 : 1
                            )
                    )
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            Text(EditorViewModel.durationLabel(block.outputDuration))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                            if abs(block.speed - 1) > 0.001 {
                                Text(EditorViewModel.speedLabel(block.speed))
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Theme.accent.opacity(0.9), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .padding(.leading, isSelected ? handleWidth + 6 : 3)
                        .padding(.top, 4)
                        .padding(.trailing, 3)
                        .padding(.bottom, 3)
                    }
                    .frame(width: block.drawWidth, height: trackHeight)
                    .offset(x: stripX + block.drawX, y: 0)
                    .allowsHitTesting(false)

                // 选中段左右各一个白色夹持把手（参考图：白色圆角块 + 中间的深色竖条）
                if isSelected {
                    handle(roundedOnLeft: true)
                        .offset(x: stripX + block.drawX, y: 0)
                        .allowsHitTesting(false)
                    handle(roundedOnLeft: false)
                        .offset(x: stripX + block.drawX + block.drawWidth - handleWidth, y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// 选中段的夹持把手：白色圆角块，外侧圆角、内侧贴齐胶片，中间一根深色竖条
    private func handle(roundedOnLeft: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: roundedOnLeft ? 8 : 0,
            bottomLeadingRadius: roundedOnLeft ? 8 : 0,
            bottomTrailingRadius: roundedOnLeft ? 0 : 8,
            topTrailingRadius: roundedOnLeft ? 0 : 8,
            style: .continuous
        )
        .fill(Color.white)
        .frame(width: handleWidth, height: trackHeight)
        .overlay(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .frame(width: 4, height: 22)
        )
    }

    // MARK: - 布局

    struct Block: Identifiable {
        var clip: EditorViewModel.Clip
        var index: Int
        /// 段在时间轴上的完整区间
        var x: CGFloat
        var width: CGFloat
        /// 让出缝隙后真正用来画框的区间
        var drawX: CGFloat
        var drawWidth: CGFloat
        var outputDuration: Double
        var speed: Double
        var id: UUID { clip.id }
    }

    private func layout(width: CGFloat, total: Double) -> [Block] {
        var blocks: [Block] = []
        var acc: Double = 0
        let count = clips.count
        for (index, clip) in clips.enumerated() {
            let fullX = CGFloat(acc / total) * width
            let fullWidth = CGFloat(clip.outputDuration / total) * width
            let leading: CGFloat = index > 0 ? clipGap / 2 : 0
            let trailing: CGFloat = index < count - 1 ? clipGap / 2 : 0
            blocks.append(
                Block(
                    clip: clip,
                    index: index,
                    x: fullX,
                    width: fullWidth,
                    drawX: fullX + leading,
                    drawWidth: max(2, fullWidth - leading - trailing),
                    outputDuration: clip.outputDuration,
                    speed: clip.speed
                )
            )
            acc += clip.outputDuration
        }
        return blocks
    }

    /// 播放头（时间轴正中）往右 x 处对应的成片时间
    private func timeAt(x: CGFloat, width: CGFloat, total: Double) -> Double {
        scrollTime + Double((x - width / 2) / width) * total
    }

    private func clamp(_ value: Double, total: Double) -> Double {
        min(max(value, 0), total)
    }

    private func clipID(at outputTime: Double) -> UUID? {
        var acc: Double = 0
        for clip in clips {
            if outputTime <= acc + clip.outputDuration { return clip.id }
            acc += clip.outputDuration
        }
        return clips.last?.id
    }

    // MARK: - 胶片

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        let count = max(frames.count, 1)
        let slot = width / CGFloat(count)
        if frames.isEmpty {
            Rectangle().fill(Color.white.opacity(0.12))
        } else {
            HStack(spacing: 0) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, image in
                    ZStack {
                        Color.white.opacity(0.12)
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: slot, height: trackHeight)
                    .clipped()
                }
            }
            .frame(width: width, height: trackHeight, alignment: .leading)
        }
    }
}

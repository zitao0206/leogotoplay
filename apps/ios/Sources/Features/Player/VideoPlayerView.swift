import SwiftUI
import LeogotoPlayCore

/// 基础播放器页：全屏播放 + 进度拖动 + 倍速 / 循环 / 画面填充，可直接进入剪辑。
struct VideoPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: PlayerViewModel
    @State private var editorSource: EditorViewModel.Source?
    @State private var toastMessage: String?

    init(item: VideoItem) {
        _viewModel = StateObject(wrappedValue: PlayerViewModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoLayerView(
                player: viewModel.player,
                videoGravity: viewModel.isAspectFill ? .resizeAspectFill : .resizeAspect
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { viewModel.togglePlay() }

            if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.black.opacity(0.45), in: Circle())
                    .onTapGesture { viewModel.play() }
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .statusBarHidden()
        .toast($toastMessage)
        .task { await viewModel.reloadDuration() }
        .fullScreenCover(item: $editorSource, onDismiss: {
            Task { await viewModel.reloadDuration() }
        }) { source in
            VideoEditorView(source: source)
                .environmentObject(library)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
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

            Button {
                editorSource = .library(viewModel.item)
            } label: {
                Label("剪辑", systemImage: "scissors")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.16), in: Capsule())
            }
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
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...max(viewModel.duration, 0.1)
            )
            .tint(Theme.accent)

            HStack(spacing: 18) {
                Button {
                    viewModel.togglePlay()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Theme.accentGradient, in: Circle())
                }

                Spacer()

                Menu {
                    ForEach(viewModel.availableRates, id: \.self) { rate in
                        Button {
                            viewModel.setRate(rate)
                        } label: {
                            if viewModel.rate == rate {
                                Label(rateLabel(for: rate), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(for: rate))
                            }
                        }
                    }
                } label: {
                    textControl(icon: "speedometer", title: viewModel.rateLabel)
                }

                Button {
                    viewModel.isLooping.toggle()
                } label: {
                    textControl(icon: "repeat", title: "循环", isActive: viewModel.isLooping)
                }

                Button {
                    viewModel.isAspectFill.toggle()
                } label: {
                    textControl(
                        icon: viewModel.isAspectFill ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                        title: "画面",
                        isActive: viewModel.isAspectFill
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func rateLabel(for rate: Float) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))x" : String(format: "%.1fx", rate)
    }

    private func textControl(icon: String, title: String, isActive: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isActive ? Theme.accentSecondary : .white.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.1)))
    }

    private var emptyControl: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

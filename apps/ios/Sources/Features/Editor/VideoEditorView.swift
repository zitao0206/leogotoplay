import SwiftUI
import LeogotoPlayCore

/// 视频剪辑页：预览 + 时间轴裁剪 + 导出到相册 / 存入素材库。
/// 支持两种入口：相册临时视频、素材库已导入视频。
struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var viewModel: EditorViewModel

    @State private var toastMessage: String?
    @State private var showExportOptions = false

    init(source: EditorViewModel.Source) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            controlPanel
        }
        .background(Color.black.ignoresSafeArea())
        .task { await viewModel.load() }
        .toast($toastMessage)
        .confirmationDialog("导出剪辑结果", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("保存到相册") { Task { await exportToAlbum() } }
            Button("存入素材库") { Task { await exportToLibrary() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("裁剪时长 \(viewModel.selectedDuration.timecode)")
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("剪辑")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(viewModel.source.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Button("重置") {
                viewModel.resetTrim()
                toastMessage = "已还原裁剪区间"
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))

            Button {
                showExportOptions = true
            } label: {
                Text("导出")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .background(Theme.accentGradient, in: Capsule())
            .disabled(viewModel.isLoading || viewModel.isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - 预览

    private var preview: some View {
        ZStack {
            VideoLayerView(
                player: viewModel.player,
                videoGravity: viewModel.isAspectFill ? .resizeAspectFill : .resizeAspect
            )

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
            } else if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.45), in: Circle())
            }

            VStack {
                Spacer()
                HStack {
                    Text(viewModel.currentTime.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(viewModel.duration.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if viewModel.isExporting {
                exportOverlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !viewModel.isLoading, !viewModel.isExporting else { return }
            viewModel.togglePlay()
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private var exportOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(value: viewModel.exportProgress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(width: 180)
            Text("正在导出 \(Int(viewModel.exportProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(18)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 控制面板

    private var controlPanel: some View {
        VStack(spacing: 14) {
            TrimRangeSlider(
                start: Binding(
                    get: { viewModel.trimStart },
                    set: { viewModel.updateTrim(start: $0) }
                ),
                end: Binding(
                    get: { viewModel.trimEnd },
                    set: { viewModel.updateTrim(end: $0) }
                ),
                duration: viewModel.duration,
                frames: viewModel.filmstrip
            )

            HStack {
                Text(viewModel.trimStart.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("选中 \(viewModel.selectedDuration.timecode)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accentSecondary)
                Spacer()
                Text(viewModel.trimEnd.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 10) {
                toolChip(icon: "scissors", title: "裁剪", isActive: true) {}
                toolChip(icon: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         title: viewModel.isMuted ? "已静音" : "原声",
                         isActive: viewModel.isMuted) {
                    viewModel.isMuted.toggle()
                }
                toolChip(icon: viewModel.isAspectFill ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                         title: viewModel.isAspectFill ? "填充" : "适应",
                         isActive: viewModel.isAspectFill) {
                    viewModel.isAspectFill.toggle()
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.togglePlay()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.14), in: Circle())
                }

                Button {
                    showExportOptions = true
                } label: {
                    Label("导出剪辑", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fillsWidth: true))
                .disabled(viewModel.isLoading || viewModel.isExporting)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: 0x17181C))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func toolChip(icon: String, title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isActive ? Theme.accentSecondary : .white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isActive ? Theme.accent.opacity(0.16) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导出动作

    private func exportToAlbum() async {
        viewModel.pause()
        guard let url = await viewModel.export() else { return }
        do {
            try await VideoExporter.saveToAlbum(url)
            toastMessage = "已保存到相册"
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func exportToLibrary() async {
        viewModel.pause()
        guard let url = await viewModel.export() else { return }
        do {
            try await library.importExport(fileURL: url, title: "\(viewModel.source.title) 剪辑版")
            toastMessage = "已存入素材库"
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: url)
    }
}

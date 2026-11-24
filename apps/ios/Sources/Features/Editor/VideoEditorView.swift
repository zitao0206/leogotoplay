import SwiftUI
import LeogotoPlayCore

/// 视频剪辑页：预览 + 播放条 + 工具条 + 分段时间轴 + 导出。
/// 支持两种入口：相册临时视频、素材库已导入视频。
struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var viewModel: EditorViewModel

    @State private var toastMessage: String?
    @State private var showExportOptions = false
    @State private var showSpeedPanel = false
    @State private var showVolumePanel = false
    @State private var volumeDraft: Double = 1
    @State private var speedDraft: Double = 1
    @Environment(\.scenePhase) private var scenePhase
    /// List 被关掉就没有素材库页，导出选项里也不再给「存入素材库」
    @AppStorage(TabPrefs.showListKey) private var showList = true

    init(source: EditorViewModel.Source) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(source: source))
    }

    private enum Tool: String, Identifiable {
        case split, delete, speed, volume, animation, filter, subtitle, sticker, transition

        var id: String { rawValue }

        var title: String {
            switch self {
            case .split: return "分割"
            case .delete: return "删除"
            case .speed: return "变速"
            case .volume: return "音量"
            case .animation: return "动画"
            case .filter: return "滤镜"
            case .subtitle: return "字幕"
            case .sticker: return "贴纸"
            case .transition: return "转场"
            }
        }

        var icon: String {
            switch self {
            case .split: return "scissors"
            case .delete: return "trash"
            case .speed: return "speedometer"
            case .volume: return "speaker.wave.2.fill"
            case .animation: return "sparkles"
            case .filter: return "camera.filters"
            case .subtitle: return "textformat"
            case .sticker: return "face.smiling"
            case .transition: return "rectangle.on.rectangle"
            }
        }

        var isReady: Bool {
            switch self {
            case .split, .delete, .speed, .volume: return true
            default: return false
            }
        }
    }

    private let tools: [Tool] = [
        .split, .delete, .speed, .volume,
        .animation, .filter, .subtitle, .sticker, .transition
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                // 预览整体下移 30pt
                preview(areaHeight: geo.size.height * 0.60, areaWidth: geo.size.width * 0.68)
                    .padding(.top, 30)
                transportRow
                timeline
                // 时间轴与功能条之间固定 30pt
                Color.clear.frame(height: 30)
                toolBar
                Spacer(minLength: 0)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture {
            // 点时间轴选区以外的地方，选中框消失
            viewModel.clearSelection()
        }
        .task { await viewModel.load() }
        // V4.0：离开剪辑页把现场存成草稿，下次从「最近编辑」点回来可以还原
        .onDisappear { viewModel.saveDraft() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { viewModel.saveDraft() }
        }
        .toast($toastMessage)
        .confirmationDialog("导出剪辑结果", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("保存到相册") { Task { await exportToAlbum() } }
            if showList {
                Button("存入素材库") { Task { await exportToLibrary() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("成片时长 \(viewModel.outputDuration.timecode)")
        }
        .sheet(isPresented: $showSpeedPanel) { speedPanel }
        .sheet(isPresented: $showVolumePanel) { volumePanel }
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - 顶栏（只有关闭、导出）

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.pause()
                viewModel.saveDraft()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            Spacer()

            // V3.2.1：顶栏只留关闭 + 导出，画面比例按钮去掉
            Button {
                viewModel.pause()
                showExportOptions = true
            } label: {
                Text("导出")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .background(Theme.accentGradient, in: Capsule())
            .disabled(!viewModel.canExport)
            .opacity(viewModel.canExport ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - 预览

    private func preview(areaHeight: CGFloat, areaWidth: CGFloat) -> some View {
        ZStack {
            VideoLayerView(
                player: viewModel.player,
                videoGravity: viewModel.isAspectFill ? .resizeAspectFill : .resizeAspect
            )

            if viewModel.isLoading {
                ProgressView().tint(.white)
            } else if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.black.opacity(0.4), in: Circle())
                    .allowsHitTesting(false)
            }

            if viewModel.isExporting {
                exportOverlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !viewModel.isLoading, !viewModel.isExporting else { return }
            // 点时间轴选区以外的地方，选中框消失
            viewModel.clearSelection()
            viewModel.togglePlay()
        }
        .frame(width: areaWidth, height: areaHeight)
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

    // MARK: - 播放条（时间 / 撤销重做）

    private var transportRow: some View {
        HStack(spacing: 4) {
            Text(viewModel.outputTime.timecode)
                .foregroundStyle(.white)
            Text("/")
                .foregroundStyle(.white.opacity(0.35))
            Text(viewModel.outputDuration.timecode)
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            historyButton(icon: "arrow.uturn.backward", enabled: viewModel.canUndo) {
                viewModel.undo()
            }
            historyButton(icon: "arrow.uturn.forward", enabled: viewModel.canRedo) {
                viewModel.redo()
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func historyButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 34, height: 34)
                .background(.white.opacity(enabled ? 0.12 : 0.05), in: Circle())
        }
        .disabled(!enabled)
    }

    // MARK: - 工具条（横向滚动）

    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tools) { tool in
                    toolButton(tool)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 58)
        .padding(.bottom, 2)
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button {
            tap(tool)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: tool.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tool.isReady ? Color.white : Color.white.opacity(0.4))
                    .frame(height: 26)
                Text(tool.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tool.isReady ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
            }
            .frame(width: 68)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.clips.isEmpty && tool.isReady)
    }

    private func tap(_ tool: Tool) {
        guard tool.isReady else {
            toastMessage = "\(tool.title) · 开发中"
            return
        }
        // 点下方功能键时也把时间轴对应段选中（参考图里的选中态）
        guard let clip = viewModel.ensureSelectedClip() else {
            toastMessage = "时间轴上还没有素材"
            return
        }
        switch tool {
        case .split:
            viewModel.split()
        case .delete:
            viewModel.deleteSelectedClip()
        case .speed:
            speedDraft = clip.speed
            showSpeedPanel = true
        case .volume:
            volumeDraft = clip.volume
            showVolumePanel = true
        default:
            break
        }
    }

    // MARK: - 时间轴

    private var timeline: some View {
        VStack(spacing: 6) {
            EditTimelineView(
                frames: viewModel.filmstrip,
                outputDuration: viewModel.outputDuration,
                clips: viewModel.clips,
                selectedClipID: viewModel.selectedClipID,
                playhead: viewModel.outputTime,
                onScrub: { time in
                    // 拖 / 点时间轴时先停下播放，避免边播边 seek 画面来回跳
                    viewModel.pauseForScrub()
                    viewModel.seek(outputTime: time)
                },
                onSelect: { id in
                    guard let id else { return }
                    viewModel.selectClip(id)
                }
            )
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    // MARK: - 变速 / 音量面板

    private var speedPanel: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("变速 · 当前段")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(EditorViewModel.speedLabel(speedDraft))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 12) {
                Text("0.25x")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: $speedDraft, in: 0.25...5.0, step: 0.05) { editing in
                    if !editing { viewModel.setSpeed(speedDraft) }
                }
                .tint(Theme.accent)
                Text("5x")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    speedDraft = 1.0
                    viewModel.setSpeed(1.0)
                } label: {
                    Text("恢复原速")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Text("改完倍速，时间轴按新的时长重排")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .presentationDetents([.height(170)])
    }

    private var volumePanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("音量 · 当前段")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((volumeDraft * 100).rounded()))%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $volumeDraft, in: 0...1) { editing in
                    if !editing { viewModel.setVolume(volumeDraft) }
                }
                .tint(Theme.accent)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .presentationDetents([.height(150)])
        .onAppear { volumeDraft = viewModel.selectedClip?.volume ?? 1 }
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

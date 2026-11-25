import AVFoundation
import AppKit
import SwiftUI
import LeogotoPlayCore

/// 编辑器数据源（macOS）：素材库视频，或从相册 / 文件临时导入的视频。
struct MacEditorSource: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let libraryVideoID: UUID?
}

@MainActor
final class MacEditorModel: ObservableObject {
    let source: MacEditorSource
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var filmstrip: [NSImage] = []
    @Published var isLoading = true
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?
    @Published var exportedURL: URL?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(source: MacEditorSource) {
        self.source = source
        self.player = AVPlayer(url: source.url)
        observePlayer()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    var selectedDuration: Double { max(0, trimEnd - trimStart) }

    private var minTrimGap: Double { min(0.2, max(0.05, duration * 0.01)) }

    func load() async {
        isLoading = true
        duration = await VideoImporter.duration(of: source.url)
        if duration <= 0 { duration = 0.01 }
        trimStart = 0
        trimEnd = duration
        // 有草稿就先还原上次的现场（裁剪区间、静音），下次从「最近编辑」点回来接着剪
        if let videoID = source.libraryVideoID, let draft = MacEditorDraftStore.draft(for: videoID) {
            let gap = minTrimGap
            trimStart = min(max(draft.trimStart, 0), max(0, duration - gap))
            trimEnd = max(min(draft.trimEnd, duration), trimStart + gap)
            isMuted = draft.isMuted
            player.isMuted = isMuted
        }
        let frames = await ThumbnailService.generateFrames(forVideoAt: source.url, duration: duration, count: 12)
        filmstrip = frames.map { NSImage(cgImage: $0, size: .zero) }
        isLoading = false
        seek(to: 0)
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func updateStart(_ value: Double) {
        trimStart = min(max(0, value), max(0, trimEnd - minTrimGap))
        seek(to: trimStart)
    }

    func updateEnd(_ value: Double) {
        trimEnd = max(min(duration, value), min(duration, trimStart + minTrimGap))
        seek(to: max(trimEnd - 0.02, 0))
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
    }

    /// 离开剪辑页时调用：打开过就存成草稿（只有素材库视频有 id）
    func saveDraft() {
        guard let videoID = source.libraryVideoID, duration > 0.1 else { return }
        MacEditorDraftStore.save(
            MacEditorDraft(trimStart: trimStart, trimEnd: trimEnd, isMuted: isMuted, updatedAt: Date()),
            for: videoID
        )
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func export() async -> URL? {
        guard selectedDuration > 0.1 else {
            errorMessage = "裁剪区间太短，至少需要 0.1 秒"
            return nil
        }
        guard !isExporting else { return nil }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        do {
            let url = try await VideoExporter.export(
                videoURL: source.url,
                trimRange: trimStart...trimEnd,
                isMuted: isMuted,
                quality: ExportSettings.quality,
                progressHandler: { [weak self] progress in
                    self?.exportProgress = progress
                }
            )
            exportedURL = url
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func observePlayer() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor in
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if self.isPlaying, seconds >= self.trimEnd - 0.03 {
                    self.seek(to: self.trimStart)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.isPlaying = false }
        }
    }
}

/// macOS 剪辑窗口：预览 + 裁剪 + 导出/入库。
struct MacEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: MacEditorModel
    @State private var quality: VideoExporter.Quality = ExportSettings.quality
    @State private var toast: String?

    init(source: MacEditorSource) {
        _model = StateObject(wrappedValue: MacEditorModel(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                inspector
                    .frame(width: 300)
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .task { await model.load() }
        .onDisappear { model.saveDraft() }
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("剪辑 · \(model.source.title)")
                    .font(.title3.weight(.semibold))
                Text("\(model.selectedDuration.timecode) / \(model.duration.timecode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MacPlayerSurface(player: model.player)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                MacTrimSlider(
                    filmstrip: model.filmstrip,
                    duration: model.duration,
                    start: Binding(
                        get: { model.trimStart },
                        set: { model.updateStart($0) }
                    ),
                    end: Binding(
                        get: { model.trimEnd },
                        set: { model.updateEnd($0) }
                    ),
                    currentTime: model.currentTime,
                    onScrub: { model.seek(to: $0) }
                )

                HStack(spacing: 12) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .help(model.isPlaying ? "暂停" : "播放")

                    Text(model.currentTime.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("回到开头") { model.seek(to: model.trimStart) }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("裁剪") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledValue("起点", model.trimStart.timecode)
                        labeledValue("终点", model.trimEnd.timecode)
                        labeledValue("时长", model.selectedDuration.timecode)
                        Button("重置区间") { model.resetTrim() }
                            .buttonStyle(.link)
                    }
                }

                section("音频") {
                    Toggle("静音导出", isOn: Binding(
                        get: { model.isMuted },
                        set: { _ in model.toggleMute() }
                    ))
                    .toggleStyle(.switch)
                }

                section("导出清晰度") {
                    Picker("", selection: $quality) {
                        ForEach(VideoExporter.Quality.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: quality) { newValue in
                        UserDefaults.standard.set(newValue.rawValue, forKey: ExportSettings.qualityKey)
                    }
                }

                if model.isExporting {
                    section("导出进度") {
                        ProgressView(value: model.exportProgress)
                        Text("\(Int(model.exportProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                section("完成后") {
                    VStack(spacing: 8) {
                        Button {
                            Task { await exportAndSaveToFile() }
                        } label: {
                            Label("导出并另存为…", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            Task { await exportAndImportToLibrary() }
                        } label: {
                            Label("存入素材库", systemImage: "square.stack.3d.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            Task { await exportAndSaveToPhotos() }
                        } label: {
                            Label("保存到「照片」", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .disabled(model.isExporting)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 动作

    private func exportAndSaveToFile() async {
        guard let exported = await model.export() else { return }
        guard let destination = MacAlerts.chooseSaveURL(suggestedName: "\(model.source.title)-\(Int(Date().timeIntervalSince1970)).mp4") else {
            return
        }
        do {
            try VideoExporter.moveExport(exported, to: destination)
            show("已保存到 \(destination.lastPathComponent)")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func exportAndImportToLibrary() async {
        guard let exported = await model.export() else { return }
        do {
            try await library.importExport(fileURL: exported, title: "\(model.source.title) 剪辑")
            show("已存入素材库")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func exportAndSaveToPhotos() async {
        guard let exported = await model.export() else { return }
        do {
            try await VideoExporter.saveToAlbum(exported)
            show("已保存到「照片」")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func show(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == text { toast = nil }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

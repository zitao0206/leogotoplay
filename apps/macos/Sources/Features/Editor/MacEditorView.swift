import AVFoundation
import AppKit
import SwiftUI
import LeogotoPlayCore

/// 编辑器数据源（macOS）：素材库视频，或从文件导入的视频。
struct MacEditorSource: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let libraryVideoID: UUID?
}

@MainActor
final class MacEditorModel: ObservableObject {
    @Published private(set) var source: MacEditorSource?
    let player = AVPlayer()

    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var filmstrip: [NSImage] = []
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?
    @Published var exportedURL: URL?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(source: MacEditorSource?) {
        self.source = source
        if let url = source?.url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
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

    var hasSource: Bool { source != nil }

    var selectedDuration: Double { max(0, trimEnd - trimStart) }

    private var minTrimGap: Double { min(0.2, max(0.05, duration * 0.01)) }

    func load() async {
        guard let source else { return }
        await loadSource(source)
    }

    /// 换一条素材：重置播放器并读时长 / 胶片 / 草稿
    func open(_ newSource: MacEditorSource) async {
        pause()
        source = nil
        duration = 0
        trimStart = 0
        trimEnd = 0
        currentTime = 0
        filmstrip = []
        source = newSource
        player.replaceCurrentItem(with: AVPlayerItem(url: newSource.url))
        await loadSource(newSource)
    }

    private func loadSource(_ source: MacEditorSource) async {
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

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// 离开剪辑页时调用：打开过就存成草稿（只有素材库视频有 id）
    func saveDraft() {
        guard let videoID = source?.libraryVideoID, duration > 0.1 else { return }
        MacEditorDraftStore.save(
            MacEditorDraft(trimStart: trimStart, trimEnd: trimEnd, isMuted: isMuted, updatedAt: Date()),
            for: videoID
        )
    }

    func export() async -> URL? {
        guard let source else { return nil }
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
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.isPlaying = false }
        }
    }
}

/// macOS 剪辑页（V2.1）：左边上下两块（视频列表 / 编辑区 + 时间轴），右边播放器。
struct MacEditorView: View {
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var model: MacEditorModel
    private let onClose: () -> Void

    @State private var quality: VideoExporter.Quality = ExportSettings.quality
    @State private var toast: String?

    init(initialSource: MacEditorSource?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: MacEditorModel(source: initialSource))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    mediaPanel
                        .frame(height: 250)
                    Divider()
                    editingPanel
                }
                .frame(width: 340)

                Divider()
                playerPanel
            }
        }
        .background(MacTheme.canvas)
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
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.saveDraft()
                onClose()
            } label: {
                Label("剪辑台", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(MacTheme.accent)

            Divider().frame(height: 16)

            Text(model.source?.title ?? "新建编辑")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if model.hasSource {
                Text("\(model.selectedDuration.timecode) / \(model.duration.timecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isExporting {
                ProgressView(value: model.exportProgress)
                    .frame(width: 90)
                Text("\(Int(model.exportProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $quality) {
                ForEach(VideoExporter.Quality.allCases) { q in
                    Text(q.title).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .onChange(of: quality) { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: ExportSettings.qualityKey)
            }

            Button {
                Task { await exportAndSaveToFile() }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasSource || model.isExporting)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 左侧：视频列表

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("视频")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(library.videos.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if library.videos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.title3)
                        .foregroundStyle(MacTheme.accent.opacity(0.7))
                    Text("素材库还没有视频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(library.videos) { item in
                            mediaRow(item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(MacTheme.surface)
    }

    private func mediaRow(_ item: VideoItem) -> some View {
        let selected = model.source?.libraryVideoID == item.id
        return Button {
            Task {
                await model.open(MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id))
            }
        } label: {
            HStack(spacing: 10) {
                MacThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 6)
                    .frame(width: 56, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.duration.timecode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? MacTheme.accent.opacity(0.20) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 左下：编辑区 + 时间轴

    private var editingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.hasSource {
                MacTrimSlider(
                    filmstrip: model.filmstrip,
                    duration: model.duration,
                    start: Binding(get: { model.trimStart }, set: { model.updateStart($0) }),
                    end: Binding(get: { model.trimEnd }, set: { model.updateEnd($0) }),
                    currentTime: model.currentTime,
                    onScrub: { model.seek(to: $0) }
                )
                .frame(height: 90)

                HStack(spacing: 10) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(model.currentTime.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("起点 \(model.trimStart.timecode) · 终点 \(model.trimEnd.timecode)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Toggle("静音", isOn: Binding(
                        get: { model.isMuted },
                        set: { _ in model.toggleMute() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                }

                HStack(spacing: 8) {
                    Button("存入素材库") { Task { await exportAndImportToLibrary() } }
                        .buttonStyle(.bordered)
                    Button("保存到「照片」") { Task { await exportAndSaveToPhotos() } }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(model.isExporting)

                Spacer(minLength: 0)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "scissors")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(MacTheme.accent.opacity(0.7))
                    Text("从上面的视频列表里选一条开始编辑")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
    }

    // MARK: - 右侧：播放器

    private var playerPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.hasSource {
                    MacPlayerSurface(player: model.player)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Color.white.opacity(0.25))
                        Text(model.isLoading ? "读取中…" : "还没有载入视频")
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.hasSource {
                HStack(spacing: 12) {
                    Text(model.currentTime.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Text(model.duration.timecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("回到开头") { model.seek(to: model.trimStart) }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(Color.black)
    }

    // MARK: - 动作

    private func exportAndSaveToFile() async {
        guard let exported = await model.export() else { return }
        let suggested = "\(model.source?.title ?? "clip")-\(Int(Date().timeIntervalSince1970)).mp4"
        guard let destination = MacAlerts.chooseSaveURL(suggestedName: suggested) else { return }
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
            try await library.importExport(fileURL: exported, title: "\(model.source?.title ?? "剪辑") 剪辑")
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
}

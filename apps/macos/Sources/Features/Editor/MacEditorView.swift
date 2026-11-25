import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

    @Published var clips: [MacClip] = []
    @Published var outputDuration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?
    @Published var exportedURL: URL?
    @Published var canUndo = false
    /// 时间轴缩放（1 = 每秒 50pt）
    @Published var zoomScale: Double = 1

    private var asset: AVURLAsset?
    private var assetDuration: Double = 0
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var audioTimeRange: CMTimeRange = .zero
    private var transform: CGAffineTransform = .identity
    private var undoStack: [[MacClip]] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(source: MacEditorSource?) {
        self.source = source
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

    var pixelsPerSecond: CGFloat { CGFloat(50 * zoomScale) }

    // MARK: - 载入

    func load() async {
        guard let source else { return }
        await open(source)
    }

    /// 换一条素材：读轨道、还原草稿、重建 composition
    func open(_ newSource: MacEditorSource) async {
        pause()
        source = newSource
        isLoading = true
        undoStack.removeAll()
        canUndo = false
        clips = []
        outputDuration = 0
        currentTime = 0

        let asset = AVURLAsset(url: newSource.url)
        self.asset = asset
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            videoTrack = tracks.first
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            if let videoTrack {
                transform = try await videoTrack.load(.preferredTransform)
            }
            if let audioTrack {
                audioTimeRange = try await audioTrack.load(.timeRange)
            }
            let cmDuration = try await asset.load(.duration)
            assetDuration = max(CMTimeGetSeconds(cmDuration), 0.1)
        } catch {
            errorMessage = "无法读取这条视频：\(error.localizedDescription)"
            assetDuration = 0
        }
        isLoading = false

        guard assetDuration > 0.1, videoTrack != nil else { return }

        let draft = newSource.libraryVideoID.flatMap { MacEditorDraftStore.draft(for: $0) }
        clips = restoredClips(from: draft)
        if let draft {
            isMuted = draft.isMuted
        }
        rebuildComposition(preserveTime: 0)
        player.isMuted = isMuted
    }

    /// 草稿里的片段按当前视频时长校验，边界不对的一律丢掉
    private func restoredClips(from draft: MacEditorDraft?) -> [MacClip] {
        guard let draft, !draft.clips.isEmpty else {
            return [MacClip(start: 0, end: assetDuration)]
        }
        let mapped = draft.clips.compactMap { clip -> MacClip? in
            let start = min(max(clip.start, 0), assetDuration)
            let end = min(max(clip.end, 0), assetDuration)
            guard end - start > 0.05 else { return nil }
            return MacClip(start: start, end: end)
        }
        return mapped.isEmpty ? [MacClip(start: 0, end: assetDuration)] : mapped
    }

    // MARK: - 播放

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard outputDuration > 0 else { return }
        if currentTime >= outputDuration - 0.05 {
            seek(to: 0)
        }
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, outputDuration))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    // MARK: - 编辑操作

    /// 撤销：片段表快照回退
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        clips = previous
        canUndo = !undoStack.isEmpty
        rebuildComposition(preserveTime: currentTime)
    }

    /// 重置：整条原片一段
    func resetTimeline() {
        pushUndo()
        clips = [MacClip(start: 0, end: assetDuration)]
        rebuildComposition(preserveTime: 0)
    }

    /// 在播放头处把当前片段切成两段
    func splitAtPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard anchor.sourceTime - clip.start > 0.05, clip.end - anchor.sourceTime > 0.05 else {
            errorMessage = "播放头离片段端点太近，分割不出有意义的片段"
            return
        }
        pushUndo()
        clips[anchor.index] = MacClip(start: clip.start, end: anchor.sourceTime)
        clips.insert(MacClip(start: anchor.sourceTime, end: clip.end), at: anchor.index + 1)
        rebuildComposition(preserveTime: currentTime)
    }

    /// 向左分割：保留播放头左侧，裁掉右边（只作用于当前片段）
    func keepLeftOfPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard anchor.sourceTime - clip.start > 0.05 else { return }
        pushUndo()
        clips[anchor.index] = MacClip(start: clip.start, end: anchor.sourceTime)
        rebuildComposition(preserveTime: currentTime)
    }

    /// 向右分割：保留播放头右侧，裁掉左边（只作用于当前片段）
    func keepRightOfPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard clip.end - anchor.sourceTime > 0.05 else { return }
        pushUndo()
        clips[anchor.index] = MacClip(start: anchor.sourceTime, end: clip.end)
        rebuildComposition(preserveTime: currentTime)
    }

    func zoomIn() { zoomScale = min(6, zoomScale * 1.5) }

    func zoomOut() { zoomScale = max(0.4, zoomScale / 1.5) }

    private func pushUndo() {
        undoStack.append(clips)
        if undoStack.count > 30 { undoStack.removeFirst() }
        canUndo = true
    }

    /// 输出时间 -> 落在哪个片段、对应源视频的哪一秒
    private func clipAt(_ outputTime: Double) -> (index: Int, sourceTime: Double)? {
        guard !clips.isEmpty else { return nil }
        var cursor = 0.0
        for (index, clip) in clips.enumerated() {
            if outputTime < cursor + clip.duration || index == clips.count - 1 {
                let local = min(max(outputTime - cursor, 0), clip.duration)
                return (index, clip.start + local)
            }
            cursor += clip.duration
        }
        return nil
    }

    // MARK: - composition

    private func rebuildComposition(preserveTime: Double?) {
        player.pause()
        isPlaying = false
        guard let videoTrack else { return }

        let composition = AVMutableComposition()
        let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        guard let compositionVideo else { return }
        compositionVideo.preferredTransform = transform

        let compositionAudio = audioTrack == nil
            ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for clip in clips {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.start, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.01, clip.duration), preferredTimescale: 600)
            )
            try? compositionVideo.insertTimeRange(range, of: videoTrack, at: cursor)

            if let audioTrack, let compositionAudio, audioTimeRange.duration > .zero {
                let start = CMTimeMaximum(range.start, audioTimeRange.start)
                let end = CMTimeMinimum(range.end, audioTimeRange.end)
                if end > start {
                    try? compositionAudio.insertTimeRange(
                        CMTimeRange(start: start, end: end),
                        of: audioTrack,
                        at: cursor + (start - range.start)
                    )
                }
            }
            cursor = cursor + range.duration
        }

        outputDuration = max(CMTimeGetSeconds(cursor), 0)
        let target = min(max(preserveTime ?? 0, 0), max(0, outputDuration - 0.02))
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        player.isMuted = isMuted
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
    }

    // MARK: - 草稿 / 导出

    func saveDraft() {
        guard let videoID = source?.libraryVideoID, !clips.isEmpty else { return }
        MacEditorDraftStore.save(
            MacEditorDraft(clips: clips, isMuted: isMuted, updatedAt: Date()),
            for: videoID
        )
    }

    func export() async -> URL? {
        guard let source, !clips.isEmpty, outputDuration > 0.1 else {
            errorMessage = "时间轴里没有可导出的片段"
            return nil
        }
        guard !isExporting else { return nil }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let exportClips = clips.map { VideoExporter.Clip(start: $0.start, end: $0.end) }
        do {
            let url = try await VideoExporter.export(
                sourceURL: source.url,
                clips: exportClips,
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
                self.currentTime = min(max(0, seconds), self.outputDuration)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = false
                self.currentTime = self.outputDuration
            }
        }
    }
}

/// macOS 剪辑页：左边「视频列表 + 编辑区 / 时间轴」，右边播放器（导出在播放器右上角）。
struct MacEditorView: View {
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var model: MacEditorModel
    private let onClose: () -> Void

    @State private var quality: VideoExporter.Quality = ExportSettings.quality
    @State private var toast: String?
    @State private var isImporting = false
    @State private var isDropTarget = false

    init(initialSource: MacEditorSource?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: MacEditorModel(source: initialSource))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: 340)
                Divider()
                playerColumn
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
                Text("\(model.currentTime.timecode) / \(model.outputDuration.timecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 左栏

    private var leftColumn: some View {
        VStack(spacing: 0) {
            mediaPanel
                .frame(height: 240)
            Divider()
            editingPanel
        }
    }

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
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.videos) { item in
                        mediaRow(item)
                    }
                    addVideoRow
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(MacTheme.surface)
    }

    private func mediaRow(_ item: VideoItem) -> some View {
        let selected = model.source?.libraryVideoID == item.id
        return HStack(spacing: 10) {
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
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.25))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? MacTheme.accent.opacity(0.20) : Color.clear)
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: item.id.uuidString as NSString)
        }
        .help("拖到下方编辑区载入这条视频")
    }

    private var addVideoRow: some View {
        Button {
            addVideo()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                Text(isImporting ? "正在读取…" : "添加视频")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(MacTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MacTheme.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MacTheme.accent.opacity(0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .padding(.top, 4)
    }

    // MARK: - 编辑区

    private var editingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasSource {
                toolRow
                MacTimelineView(
                    clips: model.clips,
                    outputDuration: model.outputDuration,
                    currentTime: model.currentTime,
                    pixelsPerSecond: Double(model.pixelsPerSecond),
                    onSeek: { model.seek(to: $0) }
                )
                .frame(height: 92)
                transportRow
                actionRow
            } else {
                dropHint
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacTheme.canvas)
        .overlay(
            Rectangle()
                .stroke(isDropTarget ? MacTheme.accent.opacity(0.7) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(MacTheme.accent.opacity(0.7))
            Text("把上面列表里的视频拖到这里")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("拖动即载入，松手后时间轴就出现在这里")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(isDropTarget ? 0.35 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            toolButton("撤销", "arrow.uturn.backward", enabled: model.canUndo) { model.undo() }
            toolButton("重置", "arrow.counterclockwise", enabled: true) { model.resetTimeline() }
            toolButton("分割", "scissors", enabled: true) { model.splitAtPlayhead() }
            toolButton("向左分割", "arrow.left.to.line", enabled: true) { model.keepLeftOfPlayhead() }
            toolButton("向右分割", "arrow.right.to.line", enabled: true) { model.keepRightOfPlayhead() }
            Spacer(minLength: 0)
            toolButton("缩小", "minus.magnifyingglass", enabled: true) { model.zoomOut() }
            toolButton("放大", "plus.magnifyingglass", enabled: true) { model.zoomIn() }
        }
    }

    private func toolButton(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 9))
            }
            .foregroundStyle(enabled ? Color.white.opacity(0.85) : Color.white.opacity(0.28))
            .frame(width: 40, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text(model.currentTime.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("片段 \(model.clips.count)")
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
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $quality) {
                ForEach(VideoExporter.Quality.allCases) { q in
                    Text(q.title).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .onChange(of: quality) { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: ExportSettings.qualityKey)
            }

            Spacer()

            Button("存入素材库") { Task { await exportAndImportToLibrary() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .disabled(model.isExporting)
    }

    // MARK: - 右栏

    private var playerColumn: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            VStack(spacing: 0) {
                canvas
                if model.hasSource {
                    playerBar
                }
            }

            exportButton
                .padding(16)
        }
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if model.hasSource {
                MacPlayerSurface(player: model.player)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.22))
                    Text("还没有载入视频")
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerBar: some View {
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
            .controlSize(.small)
            Text(model.outputDuration.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("回到开头") { model.seek(to: 0) }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private var exportButton: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                Task { await exportToFile() }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasSource || model.isExporting)

            if model.isExporting {
                ProgressView(value: model.exportProgress)
                    .frame(width: 96)
                Text("\(Int(model.exportProgress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 动作

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let id = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                guard let item = library.videos.first(where: { $0.id == id }) else { return }
                await model.open(MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id))
            }
        }
        return true
    }

    private func addVideo() {
        guard let url = MacAlerts.chooseVideoFile() else { return }
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                let temp = try VideoImporter.prepare(from: url)
                let item = try await library.importVideo(
                    fromTempURL: temp,
                    source: .files,
                    suggestedTitle: url.deletingPathExtension().lastPathComponent
                )
                VideoImporter.cleanTemporaryFile(at: temp)
                show("已添加「\(item.title)」，拖到编辑区即可载入")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func exportToFile() async {
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

    private func show(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == text { toast = nil }
        }
    }
}

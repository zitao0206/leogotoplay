import AVFoundation
import SwiftUI
import LeogotoPlayCore

/// 剪辑器 ViewModel：分段式剪辑（分割 / 删除 / 变速 / 分段音量）+ 预览 + 导出。
///
/// 内部用一条 `AVMutableComposition` 把各段拼起来：预览和导出共用同一条 composition，
/// 所以播放看到的效果和导出的结果一致；变速用 `scaleTimeRange`、音量用 `AVAudioMix`。
@MainActor
final class EditorViewModel: ObservableObject {

    /// 剪辑来源：视频库已有视频，或从相册 / 文件临时导入的视频。
    struct Source {
        enum Kind {
            case library(VideoItem)
            case temporary(URL)
        }

        let kind: Kind
        let url: URL
        let title: String

        static func library(_ item: VideoItem) -> Source {
            Source(kind: .library(item), url: item.fileURL, title: item.title)
        }

        static func temporary(_ url: URL, title: String) -> Source {
            Source(kind: .temporary(url), url: url, title: title)
        }

        var libraryItem: VideoItem? {
            if case .library(let item) = kind { return item }
            return nil
        }

        var isTemporary: Bool {
            if case .temporary = kind { return true }
            return false
        }
    }

    /// 一段素材：源文件里的 [start, end] 区间 + 倍速 + 音量。
    struct Clip: Identifiable, Equatable {
        var id = UUID()
        var start: Double
        var end: Double
        var speed: Double = 1
        var volume: Double = 1

        var sourceDuration: Double { max(0, end - start) }
        var outputDuration: Double { sourceDuration / max(speed, 0.01) }
    }

    static let frameCount = 8

    static func durationLabel(_ seconds: Double) -> String {
        String(format: "%.1fs", max(0, seconds))
    }

    static func speedLabel(_ speed: Double) -> String {
        if abs(speed - round(speed)) < 0.001 { return "\(Int(round(speed)))x" }
        if abs(speed * 10 - round(speed * 10)) < 0.001 {
            return String(format: "%.1fx", speed)
        }
        return String(format: "%.2fx", speed)
    }

    let source: Source
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var clips: [Clip] = []
    @Published var selectedClipID: UUID?
    /// 播放头位置（源素材时间，用来画在时间轴上）
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isAspectFill = true
    @Published var filmstrip: [UIImage?] = []
    @Published var isLoading = true
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 一次可撤销的状态快照
    private struct Snapshot {
        var clips: [Clip]
        var selectedClipID: UUID?
        var currentTime: Double
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let historyLimit = 40

    private var composition: AVMutableComposition?
    private var audioMix: AVAudioMix?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isRebuilding = false

    init(source: Source) {
        self.source = source
        self.player = AVPlayer(url: source.url)
        player.actionAtItemEnd = .pause
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

    // MARK: - 派生状态

    var selectedClip: Clip? {
        guard let selectedClipID else { return nil }
        return clips.first { $0.id == selectedClipID }
    }

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return nil }
        return clips.firstIndex { $0.id == selectedClipID }
    }

    /// 剪辑后成片总时长（已经算进倍速）
    var outputDuration: Double {
        clips.reduce(0) { $0 + $1.outputDuration }
    }

    /// 播放头在「成片时间」上的位置（时间轴按成片时间画）
    var outputTime: Double {
        compositionTime(forSourceTime: currentTime) ?? 0
    }

    var minClipGap: Double {
        min(0.2, max(0.05, duration * 0.01))
    }

    var canExport: Bool {
        !clips.isEmpty && outputDuration > 0.1 && !isLoading && !isExporting
    }

    // MARK: - 载入

    func load() async {
        isLoading = true
        let measured = await VideoImporter.duration(of: source.url)
        duration = max(measured, 0.01)
        let clip = Clip(start: 0, end: duration)
        clips = [clip]
        // 刚进页面不选中任何段，点时间轴或点功能键时才出现选中态
        selectedClipID = nil
        currentTime = 0
        filmstrip = Array(repeating: nil, count: Self.frameCount)

        // V4.0：有草稿就先还原上次的现场（分段、倍速、音量、播放头）
        let draft = source.libraryItem.flatMap { EditorDraftStore.draft(for: $0) }
        var playhead: Double = 0
        if let restored = restoredClips(from: draft), let first = restored.first, let last = restored.last {
            clips = restored
            playhead = min(max(draft?.playhead ?? 0, first.start), last.end)
            currentTime = playhead
            isAspectFill = draft?.isAspectFill ?? isAspectFill
        }

        await rebuildComposition(playhead: playhead, resumePlayback: false)
        isLoading = false
        seek(sourceTime: playhead)

        await refreshFilmstrip()
    }

    /// 把草稿里的分段换成内部 Clip，顺便校验边界（视频被换过或时长变短就不认）
    private func restoredClips(from draft: EditorDraft?) -> [Clip]? {
        guard let draft, !draft.clips.isEmpty else { return nil }
        let mapped = draft.clips.compactMap { data -> Clip? in
            let start = min(max(data.start, 0), duration)
            let end = min(max(data.end, 0), duration)
            guard end - start > 0.05 else { return nil }
            return Clip(start: start, end: end,
                        speed: max(data.speed, 0.1),
                        volume: min(max(data.volume, 0), 1))
        }
        guard mapped.count == draft.clips.count, !mapped.isEmpty else { return nil }
        return mapped
    }

    // MARK: - 草稿

    /// 离开剪辑页时调用：只要打开过就存成草稿（V3.6 起「最近编辑」里一律是草稿，不再区分改没改过）
    func saveDraft() {
        guard let item = source.libraryItem, duration > 0.1, !clips.isEmpty else { return }
        let data = clips.map {
            EditorDraft.ClipData(start: $0.start, end: $0.end, speed: $0.speed, volume: $0.volume)
        }
        EditorDraftStore.save(
            EditorDraft(clips: data, playhead: currentTime, isAspectFill: isAspectFill, updatedAt: Date()),
            for: item
        )
    }

    /// 按「成片时间」重新铺胶片：删掉的片段不再出现，剩下的片段首尾相接。
    func refreshFilmstrip() async {
        let count = Self.frameCount
        filmstrip = Array(repeating: nil, count: count)
        guard !clips.isEmpty, outputDuration > 0.01 else { return }

        let total = outputDuration
        let times: [Double] = (0..<count).map { index in
            let out = (Double(index) + 0.5) / Double(count) * total
            let src = sourceTime(forCompositionTime: out)
            return min(max(src, 0), max(duration - 0.01, 0))
        }

        await ThumbnailService.generateFramesStreaming(
            forVideoAt: source.url,
            times: times
        ) { [weak self] index, image in
            let frame = UIImage(cgImage: image)
            Task { @MainActor [weak self] in
                guard let self, index < self.filmstrip.count else { return }
                self.filmstrip[index] = frame
            }
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !clips.isEmpty, !isLoading else { return }
        if currentTime >= clips[clips.count - 1].end - 0.02 {
            seek(sourceTime: clips[0].start)
        }
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// 拖动 / 点按时间轴：正在播放就先停住（只在真的在播时才动，轻点不播时无副作用）。
    func pauseForScrub() {
        guard isPlaying else { return }
        pause()
    }

    /// 后退 / 前进：按成片时间走一步（已经算进倍速和删除）。
    func step(by seconds: Double) {
        guard !clips.isEmpty else { return }
        seek(outputTime: outputTime + seconds)
    }

    /// 跳到某个成片时间。
    func seek(outputTime seconds: Double) {
        guard !clips.isEmpty else { return }
        let total = max(outputDuration, 0.001)
        let clamped = min(max(0, seconds), total - 0.001)
        seek(sourceTime: sourceTime(forCompositionTime: clamped))
    }

    /// 跳到某段素材时间；落在被删掉的空隙里就吸附到最近的段首。
    func seek(sourceTime seconds: Double) {
        guard !clips.isEmpty else { return }
        var target = min(max(0, seconds), duration)

        if let clip = clips.first(where: { target >= $0.start - 0.001 && target <= $0.end + 0.001 }) {
            target = min(max(target, clip.start), clip.end - 0.02)
        } else {
            let next = clips.first { $0.start > target }
            target = next?.start ?? (clips.last?.end ?? 0) - 0.02
        }

        currentTime = target
        if let compTime = compositionTime(forSourceTime: target) {
            player.seek(
                to: CMTime(seconds: compTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    /// 保证有一段被选中：优先用当前选中段（且播放头落在里面），否则选播放头所在或最近的一段。
    @discardableResult
    func ensureSelectedClip() -> Clip? {
        if let clip = selectedClip,
           currentTime >= clip.start - 0.001,
           currentTime <= clip.end + 0.001 {
            return clip
        }
        guard !clips.isEmpty else {
            selectedClipID = nil
            return nil
        }
        let nearest = clips.min { lhs, rhs in
            distance(from: currentTime, to: lhs) < distance(from: currentTime, to: rhs)
        }
        selectedClipID = nearest?.id
        return nearest
    }

    private func distance(from time: Double, to clip: Clip) -> Double {
        if time < clip.start { return clip.start - time }
        if time > clip.end { return time - clip.end }
        return 0
    }

    /// 点时间轴选区以外的地方时取消选中
    func clearSelection() {
        selectedClipID = nil
    }

    // MARK: - 撤销 / 重做

    private func pushHistory() {
        undoStack.append(Snapshot(clips: clips, selectedClipID: selectedClipID, currentTime: currentTime))
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, selectedClipID: selectedClipID, currentTime: currentTime))
        syncHistoryFlags()
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, selectedClipID: selectedClipID, currentTime: currentTime))
        syncHistoryFlags()
        apply(next)
    }

    private func apply(_ snapshot: Snapshot) {
        clips = snapshot.clips
        selectedClipID = snapshot.selectedClipID
        if clips.isEmpty {
            pause()
            player.replaceCurrentItem(with: nil)
            composition = nil
            currentTime = 0
            filmstrip = []
            return
        }
        currentTime = min(max(0, snapshot.currentTime), duration)
        let playhead = currentTime
        Task {
            await rebuildComposition(playhead: playhead)
            await refreshFilmstrip()
        }
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        if let clip = clips.first(where: { $0.id == id }), !(currentTime >= clip.start && currentTime <= clip.end) {
            seek(sourceTime: clip.start)
        }
    }

    // MARK: - 剪辑操作

    /// 在播放头处把当前选中的段一分为二。
    func split() {
        guard let index = selectedClipIndex else { return }
        let clip = clips[index]
        var cut = currentTime
        if cut <= clip.start + minClipGap || cut >= clip.end - minClipGap {
            // 播放头没落在这一段里，就从这一段中点下刀
            cut = clip.start + clip.sourceDuration / 2
            seek(sourceTime: cut)
        }
        guard cut > clip.start + minClipGap, cut < clip.end - minClipGap else {
            errorMessage = "这一段太短，没法再分割"
            return
        }
        var head = clip
        head.end = cut
        var tail = clip
        pushHistory()
        tail.id = UUID()
        tail.start = cut
        clips[index] = head
        clips.insert(tail, at: index + 1)
        selectedClipID = tail.id
        Task {
            await rebuildComposition(playhead: cut)
            await refreshFilmstrip()
        }
    }

    /// 删除当前选中的段。
    func deleteSelectedClip() {
        guard let index = selectedClipIndex else { return }
        pushHistory()
        let removed = clips.remove(at: index)
        if clips.isEmpty {
            pause()
            player.replaceCurrentItem(with: nil)
            composition = nil
            currentTime = 0
            selectedClipID = nil
            filmstrip = []
            return
        }
        let next = clips[min(index, clips.count - 1)]
        selectedClipID = next.id
        let playhead = next.start
        currentTime = min(removed.start, duration)
        Task {
            await rebuildComposition(playhead: playhead)
            await refreshFilmstrip()
        }
    }

    /// 当前段倍速（1 表示原速）。
    func setSpeed(_ speed: Double) {
        guard let index = selectedClipIndex else { return }
        guard abs(clips[index].speed - speed) > 0.001 else { return }
        pushHistory()
        clips[index].speed = min(max(0.25, speed), 5)
        Task {
            await rebuildComposition(playhead: currentTime)
            await refreshFilmstrip()
        }
    }

    /// 当前段音量（0…1）。
    func setVolume(_ volume: Double) {
        guard let index = selectedClipIndex else { return }
        guard abs(clips[index].volume - volume) > 0.001 else { return }
        pushHistory()
        clips[index].volume = min(max(0, volume), 1)
        Task { await rebuildComposition(playhead: currentTime) }
    }

    // MARK: - 时间映射

    /// 源素材时间 → composition 时间（被删掉的空隙返回 nil）
    func compositionTime(forSourceTime seconds: Double) -> Double? {
        var acc: Double = 0
        for clip in clips {
            if seconds >= clip.start - 0.001 && seconds <= clip.end + 0.001 {
                let local = min(max(seconds - clip.start, 0), clip.sourceDuration)
                return acc + local / clip.speed
            }
            acc += clip.outputDuration
        }
        return nil
    }

    /// composition 时间 → 源素材时间
    func sourceTime(forCompositionTime seconds: Double) -> Double {
        guard !clips.isEmpty else { return 0 }
        var acc: Double = 0
        for (index, clip) in clips.enumerated() {
            let end = acc + clip.outputDuration
            if seconds <= end || index == clips.count - 1 {
                let local = min(max(seconds - acc, 0), clip.outputDuration)
                return clip.start + local * clip.speed
            }
            acc = end
        }
        return clips[0].start
    }

    // MARK: - 组装 composition

    private func rebuildComposition(playhead: Double, resumePlayback: Bool? = nil) async {
        guard !clips.isEmpty else { return }
        if isRebuilding { return }
        isRebuilding = true
        defer { isRebuilding = false }

        let wasPlaying = resumePlayback ?? isPlaying
        let asset = AVURLAsset(url: source.url)
        let comp = AVMutableComposition()

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let compVideo = comp.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            errorMessage = "该视频没有可用的视频轨道"
            return
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let compAudio = audioTrack == nil ? nil : comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        if let transform = try? await videoTrack.load(.preferredTransform) {
            compVideo.preferredTransform = transform
        }

        // 素材真实时长是插入的硬边界，区间越界会让导出直接失败（AVFoundationErrorDomain -11800）
        let loadedDuration = (try? await asset.load(.duration).seconds) ?? duration
        let mediaEnd = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : duration
        let audioTimeRange = try? await audioTrack?.load(.timeRange)
        let audioStart = max(0, audioTimeRange?.start.seconds ?? 0)
        let audioEnd = audioTimeRange?.end.seconds ?? mediaEnd

        let parameters = compAudio.map { AVMutableAudioMixInputParameters(track: $0) }
        var cursor = CMTime.zero

        for clip in clips {
            let start = max(0, min(clip.start, mediaEnd))
            let end = min(clip.end, mediaEnd)
            guard end - start > 0.01 else { continue }

            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )
            do {
                try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            } catch {
                errorMessage = "组装视频轨失败：\(error.localizedDescription)"
                return
            }

            // 音轨可能比视频短，只插入它真正覆盖到的部分，并保留段内偏移
            if let audioTrack, let compAudio {
                let aStart = max(start, audioStart)
                let aEnd = min(end, audioEnd)
                if aEnd - aStart > 0.01 {
                    let offset = CMTime(seconds: aStart - start, preferredTimescale: 600)
                    let audioRange = CMTimeRange(
                        start: CMTime(seconds: aStart, preferredTimescale: 600),
                        end: CMTime(seconds: aEnd, preferredTimescale: 600)
                    )
                    try? compAudio.insertTimeRange(audioRange, of: audioTrack, at: cursor + offset)
                }
            }

            // 倍速：把这整段的 composition 区间压缩 / 拉伸（音轨同上，保证音画同步）
            if abs(clip.speed - 1) > 0.001 {
                comp.scaleTimeRange(
                    CMTimeRange(start: cursor, duration: range.duration),
                    toDuration: CMTime(seconds: range.duration.seconds / clip.speed, preferredTimescale: 600)
                )
            }
            parameters?.setVolume(Float(clip.volume), at: cursor)
            cursor = cursor + CMTime(seconds: range.duration.seconds / clip.speed, preferredTimescale: 600)
        }

        if let parameters {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        } else {
            audioMix = nil
        }

        composition = comp
        let item = AVPlayerItem(asset: comp)
        item.audioMix = audioMix
        player.replaceCurrentItem(with: item)
        isPlaying = false

        seek(sourceTime: playhead)
        if wasPlaying {
            player.playImmediately(atRate: 1)
            isPlaying = true
        }
    }

    // MARK: - 导出

    /// 导出成片到临时目录，返回文件 URL。
    func export() async -> URL? {
        guard !clips.isEmpty else {
            errorMessage = "当前没有可导出的内容"
            return nil
        }
        guard outputDuration > 0.1 else {
            errorMessage = "成片太短，至少需要 0.1 秒"
            return nil
        }
        guard !isExporting else { return nil }

        pause()
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        do {
            let url = try await VideoExporter.export(
                sourceURL: source.url,
                clips: clips.map {
                    VideoExporter.Clip(
                        start: $0.start,
                        end: $0.end,
                        speed: $0.speed,
                        volume: Float($0.volume)
                    )
                },
                quality: ExportSettings.quality,
                progressHandler: { [weak self] progress in
                    self?.exportProgress = progress
                }
            )
            // 导出后自检：文件必须能被 AVFoundation 正常读出来；源片有声音时成片也得有音轨，
            // 否则宁可直接报错，也不要把一条无声的片子存进相册 / 视频库。
            if let problem = await exportProblem(with: url) {
                try? FileManager.default.removeItem(at: url)
                errorMessage = problem
                return nil
            }
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 导出结果自检，返回 nil 表示没问题，否则返回给用户看的错误文案。
    private func exportProblem(with url: URL) async -> String? {
        let output = AVURLAsset(url: url)
        let duration = (try? await output.load(.duration).seconds) ?? 0
        let videoCount = (try? await output.loadTracks(withMediaType: .video))?.count ?? 0
        guard videoCount > 0, duration.isFinite, duration > 0.05 else {
            return "导出的视频无法正常读取，请重试"
        }
        let sourceHasAudio = ((try? await AVURLAsset(url: source.url).loadTracks(withMediaType: .audio))?.isEmpty == false)
        let wantsAudio = sourceHasAudio && clips.contains { $0.volume > 0.001 }
        if wantsAudio {
            let outputHasAudio = ((try? await output.loadTracks(withMediaType: .audio))?.isEmpty == false)
            if !outputHasAudio {
                return "导出的视频没有声音轨道，请重试"
            }
        }
        return nil
    }

    // MARK: - 播放监听

    private func observePlayer() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite, let self else { return }
            Task { @MainActor in self.handleTick(seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let playingItem = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, playingItem === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    private func handleTick(_ compositionSeconds: Double) {
        guard !clips.isEmpty else { return }
        currentTime = sourceTime(forCompositionTime: compositionSeconds)
        if isPlaying, compositionSeconds >= outputDuration - 0.05 {
            seek(sourceTime: clips[0].start)
        }
    }
}

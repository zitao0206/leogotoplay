import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LeogotoPlayCore

/// 编辑器数据源（macOS）：素材库视频，或从文件导入的视频。
struct MacEditorSource: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let libraryVideoID: UUID?

    init(id: UUID = UUID(), url: URL, title: String, libraryVideoID: UUID?) {
        self.id = id
        self.url = url
        self.title = title
        self.libraryVideoID = libraryVideoID
    }
}

/// 编辑页里的项目素材（V2.8.5）：只属于当前项目，独立于素材库
struct MacProjectMaterial: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var title: String
    var duration: Double
}

@MainActor

final class MacEditorModel: ObservableObject {
    /// 项目 id / 标题（V2.8.6：编辑页的代表从「一条素材」变成「一个项目」）
    @Published private(set) var projectID: UUID
    @Published private(set) var title: String
    /// 项目素材（V2.8.5 起只属于本项目，独立于素材库）
    @Published private(set) var materials: [MacProjectMaterial] = []
    /// 素材首帧缩略图
    @Published private(set) var materialThumbnails: [UUID: CGImage] = [:]

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
    /// 时间轴胶片（V2.7.4）：缩略图缓存，key 带片段 id（多素材时间轴同一秒可能来自不同素材）
    @Published private(set) var filmstrip: [MacFilmKey: CGImage] = [:]
    /// 缩放档位：0 = 默认（整段 t 秒取 16 张，间隔 t/16），＋1 档分母 ×1.5，－1 档间隔 ×2（t/8、t/4）
    @Published private(set) var zoomLevel: Double = 0
    /// 胶片缓存对应的间隔，间隔一变就整块作废
    private var filmstripInterval = 0.0

    /// 每条素材的轨道（按素材 id 缓存，第一次用到时才读）
    private struct MaterialTracks {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        let audioRange: CMTimeRange
        let transform: CGAffineTransform
        let duration: Double
    }
    private var materialTracks: [UUID: MaterialTracks] = [:]

    private var undoStack: [[MacClip]] = []
    private var timeObserver: Any?
    /// 重建 composition 期间屏蔽播放器的周期回调：新 item 在 seek 完成前会把时间报成 0，
    /// 不挡住的话切割完播放头会跳回第一帧，选中态也跟着跑到最左边那段
    private var isRebuildingPlayer = false
    private var endObserver: NSObjectProtocol?
    private var filmstripTask: Task<Void, Never>?
    /// 正在生成的槽位（滚动时复用，避免同一批帧被反复请求）
    private var pendingSlots: Set<MacFilmKey> = []
    /// 到货的帧先入缓冲，批量提交给视图，避免一帧一次重绘
    private var frameBuffer: [MacFilmKey: CGImage] = [:]
    private var flushTask: Task<Void, Never>?
    private var filmstripGenerator: AVAssetImageGenerator?
    private var filmstripGenerationID = 0
    private var timelineScrollOffset: CGFloat = 0

    /// 打开时的现场（load() 里消费）
    private let pendingClips: [MacClip]
    private let pendingTime: Double?
    private let pendingZoom: Double?
    private let createdAt: Date
    private var didLoad = false

    init(project: MacProjectRecord) {
        projectID = project.id
        title = project.title
        pendingClips = project.clips
        pendingTime = project.currentTime
        pendingZoom = project.zoomLevel
        createdAt = project.createdAt
        isMuted = project.isMuted
        materials = project.materials.map { file in
            MacProjectMaterial(
                id: file.id,
                url: MacProjectStore.materialURL(for: file, projectID: project.id),
                title: file.title,
                duration: file.duration
            )
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
        filmstripTask?.cancel()
        filmstripGenerator?.cancelAllCGImageGeneration()
    }

    var hasClips: Bool { !clips.isEmpty }
    var hasMaterials: Bool { !materials.isEmpty }

    // MARK: - 时间轴缩放（V2.7.6：全部由缩略图间隔驱动）

    /// 正方形缩略图边长（= 轨道高度，MacTimelineView 的 trackHeight 用同一个常量）
    static let thumbnailSide: Double = 87
    /// 默认档：整段 t 秒取 16 张，即每 t/16 秒一张（从第一帧起算）
    static let thumbnailsAtDefault: Double = 16
    /// 缩小一档间隔 ×2：t/8、t/4（t/4 已是最小宽度）
    static let zoomOutStep: Double = 2
    static let maxZoomOutLevels: Double = 2
    /// 剪辑后为了保持「每秒像素不变」允许停到更稀的档位（界面上的缩小按钮仍只到 2 档）
    static let maxScaleOutLevels: Double = 5
    /// 放大一档按「当前档位 × 1.5」继续缩：t/(16·1.5)、t/(16·1.5²)…
    static let zoomInStep: Double = 1.5
    /// 最密：1/30s，即每秒 30 帧——到这一档就是极限
    static let minThumbnailInterval: Double = 1.0 / 30

    /// 时间轴可视宽度（由 MacTimelineView 上报，用于算可视窗口与内容落点）
    var timelineViewportWidth: CGFloat = 0
    /// 还原现场时希望时间轴滚到的播放头时间，视图拿到可视宽度后消费一次
    var restoredScrollTime: Double?

    /// 默认间隔：整段时长除以 16
    var baseThumbnailInterval: Double {
        max(outputDuration / Self.thumbnailsAtDefault, Self.minThumbnailInterval)
    }

    /// 当前间隔（秒）：由档位和整段时长算出来，不单独存，避免裁完片段后还留着旧时长的间隔
    var thumbnailInterval: Double {
        let base = baseThumbnailInterval
        let raw: Double
        if zoomLevel >= 0 {
            raw = base / pow(Self.zoomInStep, zoomLevel)
        } else {
            raw = base * pow(Self.zoomOutStep, -zoomLevel)
        }
        // 上限留宽一点：剪辑后为了「每秒像素不变」可能短暂越过按钮的缩小边界
        return min(max(raw, Self.minThumbnailInterval), base * pow(Self.zoomOutStep, Self.maxScaleOutLevels))
    }

    /// 每秒像素由间隔反推：一张正方形缩略图正好占一个间隔的宽度，胶片才严丝合缝
    var pixelsPerSecond: CGFloat { CGFloat(Self.thumbnailSide / thumbnailInterval) }
    private var pps: Double { Self.thumbnailSide / thumbnailInterval }

    var canZoomIn: Bool { thumbnailInterval > Self.minThumbnailInterval + 1e-9 }
    var canZoomOut: Bool { zoomLevel > -Self.maxZoomOutLevels + 1e-6 }

    /// 唯一缩放入口：档位与捏合都走这里
    func setZoomLevel(_ level: Double) {
        let base = baseThumbnailInterval
        // 剪辑后可能停在比按钮更稀的档位，捏合/按钮都不应该把它硬拽回来
        var lv = min(max(level, -max(Self.maxZoomOutLevels, -zoomLevel)), 0)
        if level > 0 {
            // 放大到 1/30s 就是极限，档位再高也夹住
            let ceiling = base > Self.minThumbnailInterval
                ? log(base / Self.minThumbnailInterval) / log(Self.zoomInStep)
                : 0
            lv = min(level, ceiling)
        }
        guard abs(lv - zoomLevel) > 1e-6 else { return }
        zoomLevel = lv
        updateVisibleWindow(offset: timelineScrollOffset)
    }

    /// 捏合手势给的是间隔本身，换算回档位
    func setThumbnailInterval(_ value: Double) {
        let base = baseThumbnailInterval
        guard value > 0, base > 0 else { return }
        let level = value <= base
            ? log(base / value) / log(Self.zoomInStep)
            : -log(value / base) / log(Self.zoomOutStep)
        setZoomLevel(level)
    }

    func zoomIn() { setZoomLevel(zoomLevel + 1) }
    func zoomOut() { setZoomLevel(zoomLevel - 1) }
    func resetZoom() { setZoomLevel(0) }

    // MARK: - 载入

    /// 读素材轨道 + 校验时间轴现场 + 还原播放头 / 缩放
    func load() async {
        guard !didLoad else { return }
        didLoad = true
        guard !materials.isEmpty || !pendingClips.isEmpty else { return }
        isLoading = true
        for material in materials {
            await loadTracks(for: material)
            loadThumbnail(for: material)
        }
        isLoading = false

        clips = validated(pendingClips)
        guard !clips.isEmpty else { return }
        rebuildComposition(preserveTime: pendingTime ?? 0)
        player.isMuted = isMuted
        filmstrip = [:]
        filmstripInterval = 0
        setZoomLevel(pendingZoom ?? 0)
        restoredScrollTime = pendingTime
        updateVisibleWindow(offset: timelineScrollOffset)
    }

    private func loadTracks(for material: MacProjectMaterial) async {
        let asset = AVURLAsset(url: material.url)
        var duration = max(material.duration, 0.1)
        if let cmDuration = try? await asset.load(.duration) {
            duration = max(CMTimeGetSeconds(cmDuration), 0.1)
        }
        let video = try? await asset.loadTracks(withMediaType: .video).first
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        var audioRange = CMTimeRange.zero
        if let audio, let range = try? await audio.load(.timeRange) {
            audioRange = range
        }
        let transform = (try? await video?.load(.preferredTransform)) ?? .identity
        materialTracks[material.id] = MaterialTracks(
            asset: asset,
            videoTrack: video,
            audioTrack: audio,
            audioRange: audioRange,
            transform: transform,
            duration: duration
        )
        if let index = materials.firstIndex(where: { $0.id == material.id }) {
            materials[index].duration = duration
        }
    }

    /// 首帧缩略图：优先用项目目录里缓存的那张，没有就现取并写回
    private func loadThumbnail(for material: MacProjectMaterial) {
        if let image = MacProjectStore.thumbnail(for: material.id),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            materialThumbnails[material.id] = cg
            return
        }
        let id = material.id
        let url = material.url
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let frame = try? await generator.image(at: .zero) {
                MacProjectStore.writeThumbnail(frame.image, for: id)
                self?.materialThumbnails[id] = frame.image
            }
        }
    }

    // MARK: - 素材

    /// 导入一条本地视频进项目（只进素材列表，不自动上时间轴，等用户拖）
    @discardableResult
    func importMaterial(from url: URL) async -> MacProjectMaterial? {
        do {
            let file = try await MacProjectStore.importMaterial(from: url, into: projectID)
            let material = MacProjectMaterial(
                id: file.id,
                url: MacProjectStore.materialURL(for: file, projectID: projectID),
                title: file.title,
                duration: file.duration
            )
            materials.append(material)
            if title == "未命名项目" { title = file.title }
            await loadTracks(for: material)
            loadThumbnail(for: material)
            persist()
            return material
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    func material(id: UUID) -> MacProjectMaterial? {
        materials.first { $0.id == id }
    }

    /// 把素材拖进时间轴：按拖入顺序整段追加（时间轴依次排开）
    func appendMaterials(_ ids: [UUID]) {
        let valid = ids.filter { id in
            materials.contains { $0.id == id } && materialTracks[id]?.videoTrack != nil
        }
        guard !valid.isEmpty else { return }
        // 空时间轴没有「每秒像素」可言，拿来换算档位会算出天价放大，这里单独回默认档
        let wasEmpty = clips.isEmpty
        let oldInterval = thumbnailInterval
        pushUndo()
        var appended = false
        for id in valid {
            guard let duration = materialTracks[id]?.duration, duration > 0.05 else { continue }
            clips.append(MacClip(sourceID: id, start: 0, end: duration))
            appended = true
        }
        guard appended else {
            _ = undoStack.popLast()
            canUndo = !undoStack.isEmpty
            return
        }
        rebuildComposition(preserveTime: currentTime)
        if wasEmpty {
            setZoomLevel(0)
        } else {
            keepScale(oldInterval)
        }
        persist()
    }

    /// 删素材：连同引用它的片段一起删；素材文件留在项目目录里（只在删项目时清）
    func removeMaterials(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        materials.removeAll { ids.contains($0.id) }
        for id in ids {
            materialTracks[id] = nil
            materialThumbnails[id] = nil
        }
        let touchesTimeline = clips.contains { clip in
            guard let sourceID = clip.sourceID else { return false }
            return ids.contains(sourceID)
        }
        if touchesTimeline {
            let oldInterval = thumbnailInterval
            pushUndo()
            clips.removeAll { clip in
                guard let sourceID = clip.sourceID else { return false }
                return ids.contains(sourceID)
            }
            rebuildComposition(preserveTime: currentTime)
            keepScale(oldInterval)
        }
        persist()
    }

    /// 拖到某个位置：把这一位移到 insertionIndex（插入前的下标）
    func moveClip(id: UUID, toInsertionIndex insertionIndex: Int) {
        guard let from = clips.firstIndex(where: { $0.id == id }) else { return }
        var target = min(max(insertionIndex, 0), clips.count)
        if from < target { target -= 1 }
        guard target != from else { return }
        pushUndo()
        let clip = clips.remove(at: from)
        clips.insert(clip, at: min(max(target, 0), clips.count))
        rebuildComposition(preserveTime: currentTime)
        persist()
    }

    // MARK: - 时间轴缩略图（V2.7.4：密度随缩放档位，只生成可视窗口）

    /// 视图上报可视窗口变化（滚动 / 缩放 / 窗口尺寸变化后调用），防抖后补帧
    func updateVisibleWindow(offset: CGFloat) {
        timelineScrollOffset = offset
        guard timelineViewportWidth > 1, outputDuration > 0.1 else { return }
        let interval = thumbnailInterval
        if abs(interval - filmstripInterval) > 1e-9 {
            filmstripInterval = interval
            requestFilmstrip(resetCache: true)
            return
        }
        requestFilmstrip()
    }

    /// 与 MacTimelineView 相同的内容落点规则：左端 0，片段起点就贴在面板左边
    private func timelineInset(pps: Double) -> CGFloat { MacTimelineView.leadingInset }

    /// 补帧入口：`resetCache` 只用于间隔变化（作废旧槽位、掐掉在飞的取帧）；
    /// 滚动只做防抖补帧，不打断已经在跑的批，避免来回滚动时反复取消重来
    private func requestFilmstrip(resetCache: Bool = false) {
        if resetCache {
            filmstripGenerationID += 1
            filmstripGenerator?.cancelAllCGImageGeneration()
            pendingSlots.removeAll()
            frameBuffer.removeAll()
            flushTask?.cancel()
            flushTask = nil
            filmstrip = [:]
        }
        let id = filmstripGenerationID
        filmstripTask?.cancel()
        filmstripTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.generateFilmstrip(generationID: id)
        }
    }

    /// 只解可视窗口 ± 一屏余量内的槽位；同档位下滚动复用缓存，不重复解码。
    /// 多素材（V2.8.6）：每个片段按自己的素材取帧，槽位键带上片段 id。
    private func generateFilmstrip(generationID: Int) async {
        guard timelineViewportWidth > 1, !clips.isEmpty else { return }
        let interval = thumbnailInterval
        let viewport = Double(timelineViewportWidth)
        let margin = max(2 * viewport / pps, 5)
        let visibleStart = Double(timelineScrollOffset - timelineInset(pps: pps)) / pps
        let visibleEnd = visibleStart + viewport
        let windowStart = max(0, visibleStart - margin)
        let windowEnd = visibleEnd + margin

        var cursor = 0.0
        var groups: [UUID: (asset: AVURLAsset, keys: [MacFilmKey], times: [Double])] = [:]
        for clip in clips {
            let clipStart = cursor
            let clipEnd = cursor + clip.duration
            cursor = clipEnd
            let from = max(windowStart, clipStart)
            let to = min(windowEnd, clipEnd)
            guard to > from, let sourceID = clip.sourceID,
                  let tracks = materialTracks[sourceID], tracks.videoTrack != nil else { continue }
            let assetFrom = clip.start + (from - clipStart)
            let assetTo = clip.start + (to - clipStart)
            let first = max(Int(floor(assetFrom / interval)), Int(floor(clip.start / interval)))
            let last = min(Int(ceil(assetTo / interval)), Int(ceil(clip.end / interval)))
            guard last >= first else { continue }
            var group = groups[sourceID] ?? (asset: tracks.asset, keys: [], times: [])
            for slot in first...last {
                let key = MacFilmKey(clipID: clip.id, slot: slot)
                guard filmstrip[key] == nil, !pendingSlots.contains(key) else { continue }
                group.keys.append(key)
                group.times.append(Double(slot) * interval)
            }
            groups[sourceID] = group
        }
        guard !groups.isEmpty else { return }

        for (_, group) in groups {
            guard !group.keys.isEmpty else { continue }
            pendingSlots.formUnion(group.keys)

            // 同一素材、同一时间可能被两个片段同时请求（复制成两段），同一次取帧要回填所有键
            var keysByTime: [String: [MacFilmKey]] = [:]
            var values: [NSValue] = []
            var seen: Set<String> = []
            for (key, seconds) in zip(group.keys, group.times) {
                let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1800)
                let signature = "\(time.value)-\(time.timescale)"
                keysByTime[signature, default: []].append(key)
                guard !seen.contains(signature) else { continue }
                seen.insert(signature)
                values.append(NSValue(time: time))
            }

            let generator = AVAssetImageGenerator(asset: group.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            // 间隔可以细到 1/30s，容差跟着缩，避免相邻帧取重
            let tolerance = CMTime(seconds: min(0.05, interval / 3), preferredTimescale: 1800)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            filmstripGenerator = generator

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let lock = NSLock()
                var remaining = values.count
                generator.generateCGImagesAsynchronously(forTimes: values) { requested, image, _, _, _ in
                    let signature = "\(requested.value)-\(requested.timescale)"
                    if let keys = keysByTime[signature] {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.pendingSlots.subtract(keys)
                            guard self.filmstripGenerationID == generationID, let image else { return }
                            for key in keys { self.frameBuffer[key] = image }
                            self.scheduleFrameFlush()
                        }
                    }
                    lock.lock()
                    remaining -= 1
                    let finished = remaining <= 0
                    lock.unlock()
                    if finished { continuation.resume() }
                }
            }
        }
        flushFrames()
    }

    /// 每 40ms 把缓冲里的帧一次性并进 filmstrip（一次发布 = 一次重绘）
    private func scheduleFrameFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self else { return }
            self.flushTask = nil
            self.flushFrames()
        }
    }

    private func flushFrames() {
        guard !frameBuffer.isEmpty else { return }
        var merged = filmstrip
        for (key, image) in frameBuffer { merged[key] = image }
        frameBuffer.removeAll()
        filmstrip = merged
    }

    /// 现场里的片段按素材时长校验，边界不对的一律丢掉
    private func validated(_ stored: [MacClip]) -> [MacClip] {
        var out: [MacClip] = []
        for clip in stored {
            let sourceID = clip.sourceID ?? materials.first?.id
            guard let sourceID, let duration = materialTracks[sourceID]?.duration, duration > 0.05 else { continue }
            let start = min(max(clip.start, 0), duration)
            let end = min(max(clip.end, 0), duration)
            guard end - start > 0.05 else { continue }
            out.append(MacClip(id: clip.id, sourceID: sourceID, start: start, end: end))
        }
        return out
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
        persist()
    }

    // MARK: - 编辑操作

    /// 撤销：片段表快照回退
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let oldInterval = thumbnailInterval
        clips = previous
        canUndo = !undoStack.isEmpty
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        persist()
    }

    /// 重置：按素材列表顺序，每条素材整段依次排开
    func resetTimeline() {
        pushUndo()
        clips = materials.compactMap { material in
            guard let duration = materialTracks[material.id]?.duration, duration > 0.05 else { return nil }
            return MacClip(sourceID: material.id, start: 0, end: duration)
        }
        rebuildComposition(preserveTime: 0)
        persist()
    }

    /// 在播放头处把当前片段切成两段
    func splitAtPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        // 播放头正好压在片段端点（比如刚在这一刀切过）什么都不做，不弹提示
        guard anchor.sourceTime - clip.start > 0.05, clip.end - anchor.sourceTime > 0.05 else { return }
        pushUndo()
        // V2.7.13：左段沿用原 id，右段新建，切割只重画右段，不整条闪
        clips[anchor.index] = MacClip(id: clip.id, sourceID: clip.sourceID, start: clip.start, end: anchor.sourceTime)
        clips.insert(
            MacClip(sourceID: clip.sourceID, start: anchor.sourceTime, end: clip.end),
            at: anchor.index + 1
        )
        rebuildComposition(preserveTime: currentTime)
        persist()
    }

    /// 播放头当前落在哪个片段（时间轴的选中框跟着它走）
    /// 是否选中了时间轴上的片段：点编辑区空白会取消，点时间轴/用工具按钮会重新选中
    @Published var isClipSelected = true
    /// 加一次就让时间轴滚回最左（向左分割后剩余内容顶头显示）
    @Published var scrollToStartToken = 0
    var currentClipIndex: Int? { isClipSelected ? clipAt(currentTime)?.index : nil }
    var clipCount: Int { clips.count }
    /// 播放头落在某段「里面」、且这一侧还有余量，才能对这一段做裁剪
    var canTrimBefore: Bool {
        guard let anchor = clipAt(currentTime) else { return false }
        return anchor.sourceTime - clips[anchor.index].start > 0.05
    }
    var canTrimAfter: Bool {
        guard let anchor = clipAt(currentTime) else { return false }
        return clips[anchor.index].end - anchor.sourceTime > 0.05
    }

    /// 删除播放头所在的片段；删到一段不剩就回到「拖素材进来」的空状态
    func deleteClipAtPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips.remove(at: anchor.index)
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        persist()
    }

    /// 向左裁剪（V2.7.17）：只裁「选中这一段」——把它从播放头处切掉左半，右半接着用，
    /// 前面、后面的片段一根汗毛都不动；播放指针停在（裁完后）这一段的起点。
    func trimBeforePlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard anchor.sourceTime - clip.start > 0.02 else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips[anchor.index] = MacClip(id: clip.id, sourceID: clip.sourceID, start: anchor.sourceTime, end: clip.end)
        // 播放头对准这一段的起点：它前面所有片段的时长之和
        let head = clips[..<anchor.index].reduce(0) { $0 + $1.duration }
        rebuildComposition(preserveTime: head)
        keepScale(oldInterval)
        persist()
    }

    /// 向右裁剪（V2.7.17）：同样只裁「选中这一段」——从播放头处切掉右半，
    /// 后面的片段原地保留（整体往前接上）；播放指针停在原处（新的段末）。
    func trimAfterPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard clip.end - anchor.sourceTime > 0.02 else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips[anchor.index] = MacClip(id: clip.id, sourceID: clip.sourceID, start: clip.start, end: anchor.sourceTime)
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        persist()
    }

    /// 剪辑后把缩放换算回「每秒像素不变」的档位：剩下的时间轴只变短，不被重新拉伸
    private func keepScale(_ interval: Double) {
        guard outputDuration > 0.05, interval > 0 else { return }
        let base = baseThumbnailInterval
        let raw = interval <= base
            ? log(base / interval) / log(Self.zoomInStep)
            : -log(interval / base) / log(Self.zoomOutStep)
        let ceiling = base > Self.minThumbnailInterval
            ? log(base / Self.minThumbnailInterval) / log(Self.zoomInStep)
            : 0
        let level = raw > 0 ? min(raw, ceiling) : max(raw, -Self.maxScaleOutLevels)
        guard abs(level - zoomLevel) > 1e-6 else { return }
        zoomLevel = level
        updateVisibleWindow(offset: timelineScrollOffset)
    }

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
            let end = cursor + clip.duration
            // 播放头正好压在片段交界（例如刚切完）时归右侧片段：
            // 切割后默认选中右边那一段，左侧自动变非选中
            if outputTime < end - 1e-6 || index == clips.count - 1 {
                let local = min(max(outputTime - cursor, 0), clip.duration)
                return (index, clip.start + local)
            }
            cursor = end
        }
        return nil
    }

    // MARK: - composition

    /// 按时间轴顺序把每条片段的素材拼成一条 composition（播放与导出共用）。
    /// 导出时如果静音，干脆不入音轨（省得再走 audioMix）。
    private func makeComposition(includeAudio: Bool = true) -> (composition: AVMutableComposition, total: Double) {
        let composition = AVMutableComposition()
        let total = max(clips.reduce(0) { $0 + $1.duration }, 0)
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return (composition, total)
        }
        let compositionAudio = includeAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        var transformApplied = false
        for clip in clips {
            guard let tracks = tracks(for: clip), let videoTrack = tracks.videoTrack else { continue }
            if !transformApplied {
                compositionVideo.preferredTransform = tracks.transform
                transformApplied = true
            }
            let range = CMTimeRange(
                start: CMTime(seconds: max(0, clip.start), preferredTimescale: 600),
                duration: CMTime(seconds: max(0.01, clip.duration), preferredTimescale: 600)
            )
            try? compositionVideo.insertTimeRange(range, of: videoTrack, at: cursor)

            if let audioTrack = tracks.audioTrack, let compositionAudio, tracks.audioRange.duration > .zero {
                let start = CMTimeMaximum(range.start, tracks.audioRange.start)
                let end = CMTimeMinimum(range.end, tracks.audioRange.end)
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

        return (composition, total)
    }

    private func tracks(for clip: MacClip) -> MaterialTracks? {
        if let sourceID = clip.sourceID, let tracks = materialTracks[sourceID] {
            return tracks
        }
        guard let first = materials.first else { return nil }
        return materialTracks[first.id]
    }

    private func rebuildComposition(preserveTime: Double?) {
        player.pause()
        isPlaying = false
        guard !clips.isEmpty else {
            outputDuration = 0
            currentTime = 0
            filmstrip = [:]
            filmstripInterval = 0
            player.replaceCurrentItem(with: nil)
            return
        }

        let built = makeComposition()
        outputDuration = built.total
        guard built.composition.tracks(withMediaType: .video).first != nil else { return }

        let target = min(max(preserveTime ?? 0, 0), max(0, outputDuration - 0.02))
        isRebuildingPlayer = true
        player.replaceCurrentItem(with: AVPlayerItem(asset: built.composition))
        player.isMuted = isMuted
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = target
                self.isRebuildingPlayer = false
            }
        }
    }

    // MARK: - 存档 / 导出

    /// 把整项目现场（素材清单 + 片段表 + 播放状态）写回存档，最近编辑据此还原
    func persist() {
        guard !materials.isEmpty || !clips.isEmpty else {
            MacProjectStore.remove(projectID)
            return
        }
        let record = MacProjectRecord(
            id: projectID,
            title: title,
            createdAt: createdAt,
            updatedAt: Date(),
            materials: materials.map { material in
                MacProjectMaterialFile(
                    id: material.id,
                    fileName: storedFileName(for: material),
                    title: material.title,
                    duration: material.duration
                )
            },
            clips: clips,
            isMuted: isMuted,
            currentTime: currentTime,
            zoomLevel: zoomLevel
        )
        MacProjectStore.save(record)
    }

    private func storedFileName(for material: MacProjectMaterial) -> String {
        let dir = MacProjectStore.directory(for: projectID).path
        let path = material.url.path
        if path.hasPrefix(dir + "/") {
            return material.url.lastPathComponent
        }
        return path
    }

    func export() async -> URL? {
        guard !clips.isEmpty, outputDuration > 0.1 else {
            errorMessage = "时间轴里没有可导出的片段"
            return nil
        }
        guard !isExporting else { return nil }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let built = makeComposition(includeAudio: !isMuted)
        do {
            let url = try await VideoExporter.export(
                composition: built.composition,
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
                guard seconds.isFinite, !self.isRebuildingPlayer else { return }
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

    @State private var toast: String?
    @State private var isImporting = false
    /// 时间轴的横向滚动位置（由下面的滑杆控制）
    @State private var timelineOffset: CGFloat = 0
    /// 时间轴可视宽度（时间轴上报，缩放时用于夹取偏移）
    @State private var timelineWidth: CGFloat = 0
    /// 素材区里选中的素材（V2.8.5：支持 ⌘ 多选后删除）
    @State private var selectedMaterialIDs: Set<UUID> = []
    /// 导出进度弹框
    @State private var isExportSheetPresented = false
    /// 导出失败文案（弹框内展示，不走全局 alert）
    @State private var exportErrorText: String?
    /// 空编辑区是否正被拖拽悬停
    @State private var isDropTargeted = false

    init(project: MacProjectRecord) {
        _model = StateObject(wrappedValue: MacEditorModel(project: project))
    }

    var body: some View {
        GeometryReader { geo in
            // V2.3：左右按 64 : 36 分（左侧素材 + 时间轴、右侧播放器），和剪映专业版一致
            let leftWidth = min(max(560, geo.size.width * 0.64), geo.size.width - 420)
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    leftColumn
                        .frame(width: leftWidth)
                    Divider()
                    playerColumn
                }
            }
        }
        .background(MacTheme.canvas)
        .modifier(DeleteKeyMonitor { handleDeleteKey() })
        .modifier(SpaceKeyMonitor { model.togglePlay() })
        .onChange(of: model.scrollToStartToken) { _ in
            // 向左分割后剩下一段从 00:00 开始，把时间轴滚回最左跟着走
            timelineOffset = timelineInset
        }
        .task {
            await model.load()
        }
        .onDisappear { model.persist() }
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $isExportSheetPresented) {
            MacExportSheet(model: model, errorText: exportErrorText) {
                isExportSheetPresented = false
            }
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
            Text(model.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if !model.hasClips {
                Text("空白项目")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MacTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MacTheme.accent.opacity(0.14), in: Capsule())
            }

            if model.hasClips {
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
        GeometryReader { geo in
            VStack(spacing: 0) {
                mediaPanel
                    .frame(height: max(270, geo.size.height * 0.44))
                Divider()
                editingPanel
            }
        }
    }

    // MARK: - 素材区（V2.8.5：正方形 cell + 首帧缩略图 + 添加 / 单选多选删除）

    /// 素材区：本项目导入过的视频按正方形 cell 排列，默认窄列宽 128pt，最后一格是「添加视频」
    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("素材")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                if !selectedMaterialIDs.isEmpty {
                    Button {
                        confirmDeleteSelectedMaterials()
                    } label: {
                        Label("删除 \(selectedMaterialIDs.count)", systemImage: "trash")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.red.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("删除选中的素材（也可以按 Delete 键）")
                }

                Spacer(minLength: 0)

                if isImporting {
                    Text("正在读取…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: materialSide, maximum: materialSide), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.materials) { material in
                        materialCell(material)
                    }
                    addMaterialCell
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(
            MacTheme.surface
                .contentShape(Rectangle())
                .onTapGesture { selectedMaterialIDs.removeAll() }
        )
    }

    private var materialSide: CGFloat { 128 }

    private func materialCell(_ material: MacProjectMaterial) -> some View {
        let picked = selectedMaterialIDs.contains(material.id)
        // 不用 Button：Button 会把鼠标按下攥在手里，拖拽起不来。点用 onTapGesture，拖用 onDrag
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                materialThumbnail(material)
                    .frame(width: materialSide, height: materialSide)
                    .clipped()

                Text(material.duration.timecode)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        picked ? MacTheme.accent : Color.white.opacity(0.08),
                        lineWidth: picked ? 2 : 1
                    )
            )

            Text(material.title)
                .font(.caption)
                .foregroundStyle(picked ? Color.white : Color.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .padding(2)
        .background(
            picked ? Color.white.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onTapGesture {
            handleMaterialTap(material)
        }
        // V2.8.6：素材要靠拖进时间轴才会上轨道；⌘ 多选后可一次拖一组
        .onDrag {
            NSItemProvider(object: dragPayload(for: material) as NSString)
        }
        .help("拖到时间轴添加；⌘ 点选可多选，Delete 键删除")
    }

    /// 正方形首帧缩略图（取不到就显示占位图标）
    @ViewBuilder
    private func materialThumbnail(_ material: MacProjectMaterial) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image = model.materialThumbnails[material.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
    }

    private var addMaterialCell: some View {
        Button {
            addVideo()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("添加视频")
                    .font(.caption)
            }
            .foregroundStyle(MacTheme.accent)
            .frame(width: materialSide, height: materialSide)
            .background(
                MacTheme.accent.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MacTheme.accent.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .help("导入一条本地视频")
    }

    /// 点 cell：⌘ 点击切换多选；普通点击只选中（V2.8.6：素材要靠拖进时间轴才会上轨道）
    private func handleMaterialTap(_ material: MacProjectMaterial) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedMaterialIDs.contains(material.id) {
                selectedMaterialIDs.remove(material.id)
            } else {
                selectedMaterialIDs.insert(material.id)
            }
            return
        }
        selectedMaterialIDs = [material.id]
    }

    private func confirmDeleteSelectedMaterials() {
        guard !selectedMaterialIDs.isEmpty else { return }
        deleteSelectedMaterials()
    }

    /// 删素材：从项目里移除，引用它的片段一起从时间轴消失
    private func deleteSelectedMaterials() {
        let ids = selectedMaterialIDs
        guard !ids.isEmpty else { return }
        selectedMaterialIDs.removeAll()
        model.removeMaterials(ids)
    }

    // MARK: - 编辑区

    private var editingPanel: some View {
        VStack(spacing: 0) {
            if !model.clips.isEmpty {
                toolRow
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                Spacer(minLength: 8)

                MacTimelineView(
                    clips: model.clips,
                    frames: model.filmstrip,
                    thumbnailInterval: model.thumbnailInterval,
                    selectedIndex: model.currentClipIndex,
                    outputDuration: model.outputDuration,
                    currentTime: model.currentTime,
                    pixelsPerSecond: Double(model.pixelsPerSecond),
                    scrollOffset: $timelineOffset,
                    onSeek: { time in
                        model.isClipSelected = true
                        model.seek(to: time)
                    },
                    onSetThumbnailInterval: { interval in
                        model.setThumbnailInterval(interval)
                    },
                    onViewportChange: { width in
                        timelineWidth = width
                        model.timelineViewportWidth = width
                        // 从「最近编辑」进来：把上次的播放头位置滚进视野（只消费一次）
                        if let t = model.restoredScrollTime, width > 1 {
                            model.restoredScrollTime = nil
                            timelineOffset = max(0, timelineInset + CGFloat(t) * model.pixelsPerSecond - width / 3)
                        }
                        model.updateVisibleWindow(offset: timelineOffset)
                    },
                    onDeselect: {
                        model.isClipSelected = false
                    },
                    onDropPayload: { payload, x in
                        handleTimelineDrop(payload: payload, x: x)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .onChange(of: timelineOffset) { newOffset in
                    // 拖动查看时间轴时按需补可视窗口内的缩略图
                    model.updateVisibleWindow(offset: newOffset)
                }
            } else {
                emptyTimelineState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // V2.7.8：点时间轴以外的空白处取消选中
        .background(
            MacTheme.canvas
                .contentShape(Rectangle())
                .onTapGesture { model.isClipSelected = false }
        )
    }

    /// 还没拖进视频时的编辑区（V2.7.9）：置灰的工具条 + 空刻度尺 + 虚线拖入区
    private var emptyTimelineState: some View {
        VStack(spacing: 0) {
            toolRow
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .disabled(true)
                .opacity(0.40)

            emptyRuler
                .frame(height: 26)
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 1)
                        .padding(.leading, 12 + 26)
                }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                Text("把左侧素材拖到这条时间轴上，开始你的大作吧～")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.015))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .padding(.horizontal, 12)
            .onDrop(of: [.text], isTargeted: $isDropTargeted) { providers in
                appendDroppedMaterials(providers)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? MacTheme.accent : Color.clear,
                        lineWidth: 1
                    )
                    .padding(.horizontal, 12)
            )

            Spacer(minLength: 0)
        }
    }

    /// 空状态下的一条静态刻度尺（没有素材时没有 pps，按 1 秒 = 160pt 画）
    private var emptyRuler: some View {
        Canvas { ctx, size in
            let pps: CGFloat = 260
            let inset: CGFloat = 26
            var t = 0.0
            while inset + CGFloat(t) * pps <= size.width {
                let x = inset + CGFloat(t) * pps
                for i in 1..<5 {
                    let mx = x + CGFloat(Double(i) * 0.2) * pps
                    guard mx <= size.width else { continue }
                    var minor = Path()
                    minor.move(to: CGPoint(x: mx, y: size.height))
                    minor.addLine(to: CGPoint(x: mx, y: size.height - 5))
                    ctx.stroke(minor, with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
                var major = Path()
                major.move(to: CGPoint(x: x, y: size.height))
                major.addLine(to: CGPoint(x: x, y: size.height - 10))
                ctx.stroke(major, with: .color(.white.opacity(0.45)), lineWidth: 1)

                let label = Text(t.timecode)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
                ctx.draw(label, at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
                t += 1
            }
        }
    }

    private var toolRow: some View {
        // V2.7.15：按钮间距 10pt → 15pt（1.5 倍）；左右分割两个按键互换位置
        HStack(spacing: 15) {
            MacGlyphButton(title: "撤销", kind: .undo, enabled: model.canUndo) {
                model.undo()
            }
            MacGlyphButton(title: "重置", kind: .reset, enabled: true) {
                model.resetTimeline()
            }
            MacGlyphButton(title: "分割", kind: .split, enabled: true) {
                model.splitAtPlayhead()
            }
            // V2.7.16：两个裁剪按钮按位置对齐语义——左边这个删左、右边这个删右；
            // 图标也跟着动作走：虚线那一侧就是要被删掉的那一侧
            MacGlyphButton(title: "向左裁剪", kind: .keepRight, enabled: model.canTrimBefore) {
                model.trimBeforePlayhead()
            }
            MacGlyphButton(title: "向右裁剪", kind: .keepLeft, enabled: model.canTrimAfter) {
                model.trimAfterPlayhead()
            }
            MacGlyphButton(
                title: "删除",
                kind: .trash,
                enabled: model.currentClipIndex != nil,
                emphasized: model.currentClipIndex != nil
            ) {
                model.deleteClipAtPlayhead()
            }

            Spacer(minLength: 0)

            MacToolIconButton(title: "时间轴缩小", icon: "minus.magnifyingglass", enabled: model.canZoomOut) {
                zoomTimeline(zoomIn: false)
            }
            MacToolIconButton(title: "时间轴放大", icon: "plus.magnifyingglass", enabled: model.canZoomIn) {
                zoomTimeline(zoomIn: true)
            }
        }
    }

    // MARK: - 右栏

    private var playerColumn: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            VStack(spacing: 0) {
                canvas
                if model.hasClips {
                    playerBar
                }
            }

            exportButton
                .padding(.top, 8)
                .padding(.trailing, 12)
        }
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if model.hasClips {
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
        // V2.8.0：播放 / 暂停键居中放大（52pt 圆钮 + 品牌色渐变），时间码靠左、回到开头靠右
        ZStack {
            HStack(spacing: 10) {
                Text(model.currentTime.timecode)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                Text("/")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                Text(model.outputDuration.timecode)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))

                Spacer(minLength: 0)

                Button("回到开头") { model.seek(to: 0) }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }

            Button {
                model.togglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(MacTheme.accentGradient)
                        .frame(width: 52, height: 52)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("播放 / 暂停（空格键）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 68)
        .background(Color.black)
    }

    private var exportButton: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                startExport()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                    Text("导出")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(MacTheme.accentGradient, in: Capsule())
                .contentShape(Capsule())
                .opacity(model.hasClips && !model.isExporting ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasClips || model.isExporting)

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

    /// V2.7.6：按钮档位式缩放（放大一档分母 ×1.5、缩小一档间隔 ×2，由模型执行），以播放指针为锚点——
    /// 缩放前后指针在屏上的位置不动，同时把偏移夹进新内容范围。
    private func zoomTimeline(zoomIn: Bool) {
        if zoomIn {
            model.zoomIn()
        } else {
            model.zoomOut()
        }

        // V2.7.8：缩放以时间轴 00:00 为锚，左边固定不动，只把滚动偏移夹回新范围
        let newPPS = model.pixelsPerSecond
        let maxOffset = max(0, CGFloat(model.outputDuration) * newPPS + timelineInset * 2 - timelineWidth)
        timelineOffset = min(max(0, timelineOffset), maxOffset)
        // 偏移可能没变（onChange 不触发），显式上报一次让缩略图按新档位重建
        model.updateVisibleWindow(offset: timelineOffset)
    }

    /// 内容落点：左端不留余量，片段起点（0.00）永远贴住面板左边，不随缩放漂移
    private var timelineInset: CGFloat { MacTimelineView.leadingInset }

    /// Delete 键（V2.8.5）：素材区有选中就先删素材，否则删时间轴上选中的片段
    private func handleDeleteKey() {
        if !selectedMaterialIDs.isEmpty {
            deleteSelectedMaterials()
            return
        }
        guard model.isClipSelected, model.currentClipIndex != nil else { return }
        model.deleteClipAtPlayhead()
    }

    /// V2.8.4：编辑页不再导入素材库 —— 选中的本地文件直接载进时间轴
    private func addVideo() {
        guard let url = MacAlerts.chooseVideoFile() else { return }
        importVideo(from: url)
    }

    /// 选中的本地文件拷进项目目录，只进素材列表（V2.8.6：要不要上时间轴由用户拖决定）
    private func importVideo(from url: URL) {
        Task {
            isImporting = true
            defer { isImporting = false }
            guard let material = await model.importMaterial(from: url) else {
                if let message = model.errorMessage {
                    show(message)
                    model.errorMessage = nil
                }
                return
            }
            selectedMaterialIDs = [material.id]
        }
    }

    // MARK: - 拖进时间轴

    /// 素材 cell 的拖拽载荷：多选时一次带上整组（按素材列表顺序）
    private func dragPayload(for material: MacProjectMaterial) -> String {
        let ids = selectedMaterialIDs.contains(material.id) ? selectedMaterialIDs : [material.id]
        let ordered = model.materials.filter { ids.contains($0.id) }.map { $0.id.uuidString }
        return "mat:" + ordered.joined(separator: "|")
    }

    /// 空编辑区接收拖入（无位置概念，直接按顺序追加）
    private func appendDroppedMaterials(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? NSString else { return }
                let ids = self.materialIDs(from: payload as String)
                guard !ids.isEmpty else { return }
                Task { @MainActor in
                    self.selectedMaterialIDs = Set(ids)
                    self.model.appendMaterials(ids)
                }
            }
        }
        return true
    }

    /// 时间轴里的落点：素材按顺序追加；片段按 x 算插入位置
    private func handleTimelineDrop(payload: String, x: CGFloat) {
        if payload.hasPrefix("clip:") {
            guard let id = UUID(uuidString: String(payload.dropFirst(5))) else { return }
            let time = Double(max(0, x + timelineOffset - timelineInset)) / Double(model.pixelsPerSecond)
            var insertion = 0
            var cursor = 0.0
            for clip in model.clips {
                if time > cursor + clip.duration / 2 { insertion += 1 }
                cursor += clip.duration
            }
            model.moveClip(id: id, toInsertionIndex: insertion)
            return
        }
        let ids = materialIDs(from: payload)
        guard !ids.isEmpty else { return }
        selectedMaterialIDs = Set(ids)
        model.appendMaterials(ids)
    }

    private func materialIDs(from payload: String) -> [UUID] {
        let body = payload.hasPrefix("mat:") ? String(payload.dropFirst(4)) : payload
        return body.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
    }

    // MARK: - 导出（V2.8.0 起带进度弹框，默认落到「下载」文件夹）

    /// 点导出：先把弹框顶上来，再在后台渲染时间轴，进度实时写进 model.exportProgress
    private func startExport() {
        guard !model.clips.isEmpty, !model.isExporting else { return }
        model.pause()
        model.exportedURL = nil
        exportErrorText = nil
        isExportSheetPresented = true
        Task { await runExport() }
    }

    private func runExport() async {
        guard let exported = await model.export() else {
            // 失败信息放进弹框里，同时清掉全局 alert 的文案，避免两层弹窗叠一起
            exportErrorText = model.errorMessage ?? "导出失败，请稍后再试"
            model.errorMessage = nil
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let base = model.title.replacingOccurrences(of: "/", with: "-")
        let destination = MacExportPaths.downloads
            .appendingPathComponent("\(base)-\(stamp).mp4")
        do {
            try VideoExporter.moveExport(exported, to: destination)
            model.exportedURL = destination
        } catch {
            exportErrorText = error.localizedDescription
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

// MARK: - 导出进度弹框（V2.8.0）

private enum MacExportPaths {
    /// 默认导出目录：用户「下载」文件夹
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}

private struct MacExportSheet: View {
    @ObservedObject var model: MacEditorModel
    let errorText: String?
    let onClose: () -> Void

    private var progress: Double { min(max(model.exportProgress, 0), 1) }
    private var isDone: Bool { model.exportedURL != nil && !model.isExporting }

    private var title: String {
        if isDone { return "导出完成" }
        if errorText != nil { return "导出失败" }
        return "正在导出"
    }

    private var titleIcon: String {
        if isDone { return "checkmark.circle.fill" }
        if errorText != nil { return "exclamationmark.triangle.fill" }
        return "arrow.up.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: titleIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("默认导出到「下载」文件夹：\(MacExportPaths.downloads.path)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .textSelection(.enabled)

            if model.isExporting {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(MacTheme.accent)
                HStack {
                    Text("正在渲染时间轴…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }

            if let url = model.exportedURL, !model.isExporting {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xFF7A63))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if isDone, let url = model.exportedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Text("在访达中显示")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Text(isDone ? "完成" : "关闭")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(MacTheme.accentGradient, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(MacTheme.surface)
    }
}

// MARK: - 编辑工具图标按钮

/// V2.5：工具栏图标按剪映的样子来 —— 只有图标、没有文字，悬停时淡淡一层底
private struct MacToolIconButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    var emphasized: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(enabled ? Color.white.opacity(hovering ? 1 : (emphasized ? 0.95 : 0.82)) : Color.white.opacity(0.22))
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            hovering && enabled
                                ? Color.white.opacity(0.12)
                                : Color.white.opacity(emphasized ? 0.07 : 0)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(emphasized ? 0.12 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

// MARK: - 自绘工具图标

/// V2.7.2：撤销 / 重置 / 分割 / 向左分割 / 向右分割 / 删除 六个图标全部按参考图自绘。
/// 26pt 设计栅格、方头粗线（主线条 3.0、垃圾桶 2.4），尺寸与形体对齐剪映那套图标：
/// - 撤销 / 重置 = 半圆回转箭头 + 顶端单根斜刺（不是双撇 chevron）
/// - 分割 = 两个短脚括号 `][`
/// - 向左 / 向右分割 = 一个括号 + 一列方块虚线（虚线侧为被裁掉的部分）
/// - 删除 = 满宽桶盖 + 顶部小提手 + 近满宽方形桶身
private struct MacEditorGlyph: View {
    enum Kind {
        case undo
        case reset
        case split
        case keepLeft
        case keepRight
        case trash
    }

    let kind: Kind
    var tint: Color = .white

    private let design: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / design

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }

            /// 用折线拼半圆，避开 Path.addArc 在不同坐标系下的方向歧义
            func addArc(
                _ path: inout Path,
                center: CGPoint,
                radius: CGFloat,
                from startDeg: CGFloat,
                to endDeg: CGFloat,
                scale: CGFloat
            ) {
                let steps = 24
                let r = radius * scale
                for step in 1...steps {
                    let t = startDeg + (endDeg - startDeg) * CGFloat(step) / CGFloat(steps)
                    let rad = t * .pi / 180
                    path.addLine(to: CGPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad)))
                }
            }

            func stroke(_ path: Path, width: CGFloat, dash: [CGFloat]? = nil) {
                context.stroke(
                    path,
                    with: .color(tint),
                    style: StrokeStyle(
                        lineWidth: width * scale,
                        lineCap: dash == nil ? .square : .butt,
                        lineJoin: .miter,
                        dash: (dash ?? []).map { $0 * scale }
                    )
                )
            }

            var solid = Path()
            var dashed = Path()

            switch kind {
            case .undo:
                solid.move(to: point(2, 22.5))
                solid.addLine(to: point(17, 22.5))
                addArc(&solid, center: point(17, 14.5), radius: 8.0, from: 90, to: -90, scale: scale)
                solid.addLine(to: point(2, 6.5))
                solid.move(to: point(2, 6.5))
                solid.addLine(to: point(6, 1.5))
                stroke(solid, width: 3.4)

            case .reset:
                solid.move(to: point(24, 22.5))
                solid.addLine(to: point(9, 22.5))
                addArc(&solid, center: point(9, 14.5), radius: 8.0, from: 90, to: 270, scale: scale)
                solid.addLine(to: point(24, 6.5))
                solid.move(to: point(24, 6.5))
                solid.addLine(to: point(20, 1.5))
                stroke(solid, width: 3.4)

            case .split:
                // 左「]」右「[」，短脚
                solid.move(to: point(8, 0.6))
                solid.addLine(to: point(8, 25.4))
                solid.move(to: point(8, 1))
                solid.addLine(to: point(3.5, 1))
                solid.move(to: point(8, 25))
                solid.addLine(to: point(3.5, 25))

                solid.move(to: point(18, 0.6))
                solid.addLine(to: point(18, 25.4))
                solid.move(to: point(18, 1))
                solid.addLine(to: point(22.5, 1))
                solid.move(to: point(18, 25))
                solid.addLine(to: point(22.5, 25))
                stroke(solid, width: 3.4)

            case .keepLeft:
                // 保留左侧：左边括号「]」，右边虚线
                solid.move(to: point(9, 0.6))
                solid.addLine(to: point(9, 25.4))
                solid.move(to: point(9, 1))
                solid.addLine(to: point(4.5, 1))
                solid.move(to: point(9, 25))
                solid.addLine(to: point(4.5, 25))

                dashed.move(to: point(18.5, 1))
                dashed.addLine(to: point(18.5, 25))
                stroke(solid, width: 3.4)
                stroke(dashed, width: 3.4, dash: [3.0, 2.0])

            case .keepRight:
                // 保留右侧：左边虚线，右边括号「[」
                solid.move(to: point(17, 0.6))
                solid.addLine(to: point(17, 25.4))
                solid.move(to: point(17, 1))
                solid.addLine(to: point(21.5, 1))
                solid.move(to: point(17, 25))
                solid.addLine(to: point(21.5, 25))

                dashed.move(to: point(7.5, 1))
                dashed.addLine(to: point(7.5, 25))
                stroke(solid, width: 3.4)
                stroke(dashed, width: 3.4, dash: [3.0, 2.0])

            case .trash:
                // 满宽桶盖 + 中央小提手 + 近满宽方形桶身
                solid.move(to: point(1, 3.4))
                solid.addLine(to: point(25, 3.4))
                solid.move(to: point(13, 3.4))
                solid.addLine(to: point(13, 0.6))
                solid.move(to: point(4.5, 3.4))
                solid.addLine(to: point(4.5, 24.6))
                solid.addLine(to: point(21.5, 24.6))
                solid.addLine(to: point(21.5, 3.4))
                stroke(solid, width: 2.7)
            }
        }
        .frame(width: 22, height: 22)
    }
}
/// 自绘图标按钮：尺寸、悬停底色、禁用态与其它工具按钮完全一致
private struct MacGlyphButton: View {
    let title: String
    let kind: MacEditorGlyph.Kind
    let enabled: Bool
    var emphasized: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var tint: Color {
        guard enabled else { return Color.white.opacity(0.30) }
        if hovering { return .white }
        return Color.white.opacity(emphasized ? 0.95 : 0.82)
    }

    var body: some View {
        Button(action: action) {
            MacEditorGlyph(kind: kind, tint: tint)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            hovering && enabled
                                ? Color.white.opacity(0.12)
                                : Color.white.opacity(emphasized && enabled ? 0.07 : 0)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

// MARK: - 播放器的空格键监听

/// V2.8.0：剪辑窗口里按空格切换播放 / 暂停。文字输入框聚焦时原样放行，
/// ⌘ / ⌥ 组合键（系统快捷键，如 ⌘Space）不拦；其余情况吞掉空格，避免顺带触发聚焦按钮。
private struct SpaceKeyMonitor: ViewModifier {
    let onSpace: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window = event.window, window.title.contains("剪辑") else { return event }
                    guard event.keyCode == 49 else { return event }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) { return event }
                    if window.firstResponder is NSTextView { return event }
                    onSpace()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

// MARK: - 素材列表的 Delete 键监听

/// 剪辑窗口里按 Delete / 前向 Delete 删掉选中的素材（不吞主窗口和其他文字输入的键）
private struct DeleteKeyMonitor: ViewModifier {
    let onDelete: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window = event.window, window.title.contains("剪辑") else { return event }
                    guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                    if window.firstResponder is NSTextView { return event }
                    onDelete()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

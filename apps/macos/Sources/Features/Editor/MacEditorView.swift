import AVFoundation
import AppKit
import SwiftUI
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
    /// 时间轴胶片（V2.7.4）：缩略图缓存，key = 槽位序号，覆盖时间 = 序号 × thumbnailInterval。
    /// 只生成/保留可视窗口附近的槽位，缩放档位变化时清空重建。
    @Published private(set) var filmstrip: [Int: CGImage] = [:]
    /// 缩放档位：0 = 默认（整段 t 秒取 16 张，间隔 t/16），＋1 档分母 ×1.5，－1 档间隔 ×2（t/8、t/4）
    @Published private(set) var zoomLevel: Double = 0
    /// 胶片缓存对应的间隔，间隔一变就整块作废
    private var filmstripInterval = 0.0

    private var asset: AVURLAsset?
    private var assetDuration: Double = 0
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var audioTimeRange: CMTimeRange = .zero
    private var transform: CGAffineTransform = .identity
    private var undoStack: [[MacClip]] = []
    private var timeObserver: Any?
    /// 重建 composition 期间屏蔽播放器的周期回调：新 item 在 seek 完成前会把时间报成 0，
    /// 不挡住的话切割完播放头会跳回第一帧，选中态也跟着跑到最左边那段
    private var isRebuildingPlayer = false
    private var endObserver: NSObjectProtocol?
    private var filmstripTask: Task<Void, Never>?
    /// 正在生成的槽位（滚动时复用，避免同一批帧被反复请求）
    private var pendingSlots: Set<Int> = []
    /// 到货的帧先入缓冲，批量提交给视图，避免一帧一次重绘
    private var frameBuffer: [Int: CGImage] = [:]
    private var flushTask: Task<Void, Never>?
    private var filmstripGenerator: AVAssetImageGenerator?
    private var filmstripGenerationID = 0
    private var timelineScrollOffset: CGFloat = 0
    private var visibleStartTime: Double = 0
    private var visibleEndTime: Double = 0
    /// 新项目标记（V2.8.2）：从首页「开始编辑」进来的窗口 source 为 nil，
    /// 之后往里拖素材也不还原这条素材上次的草稿（裁点 / 播放头 / 缩放 / 静音），保证是从头开始的干净项目。
    /// 从「最近编辑」或素材库带着 source 打开的窗口仍然照常还原草稿。
    private let restoresDraft: Bool

    init(source: MacEditorSource?) {
        self.source = source
        self.restoresDraft = source != nil
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

    var hasSource: Bool { source != nil }

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
    /// 还原草稿时希望时间轴滚到的播放头时间，视图拿到可视宽度后消费一次
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

        let draft = restoresDraft ? newSource.libraryVideoID.flatMap { MacEditorDraftStore.draft(for: $0) } : nil
        clips = restoredClips(from: draft)
        if let draft {
            isMuted = draft.isMuted
        }
        let restoredTime = min(max(draft?.currentTime ?? 0, 0), max(0, clips.reduce(0) { $0 + $1.duration } - 0.02))
        rebuildComposition(preserveTime: restoredTime)
        player.isMuted = isMuted
        // 换素材：胶片整块作废后重建；缩放档位按草稿还原（没有草稿就是默认档）
        filmstrip = [:]
        filmstripInterval = 0
        setZoomLevel(draft?.zoomLevel ?? 0)
        // 从「最近编辑」进来时让时间轴滚回上次的位置
        restoredScrollTime = draft?.currentTime
        updateVisibleWindow(offset: timelineScrollOffset)
    }

    // MARK: - 时间轴缩略图（V2.7.4：密度随缩放档位，只生成可视窗口）

    /// 视图上报可视窗口变化（滚动 / 缩放 / 窗口尺寸变化后调用），防抖后补帧
    func updateVisibleWindow(offset: CGFloat) {
        timelineScrollOffset = offset
        let width = timelineViewportWidth
        guard width > 1, outputDuration > 0.1 else { return }
        // 间隔变了（缩放档位或整段时长变化），旧槽位全部失效
        let interval = thumbnailInterval
        if abs(interval - filmstripInterval) > 1e-9 {
            filmstripInterval = interval
            requestFilmstrip(resetCache: true)
            return
        }
        let ins = timelineInset(pps: pps)
        // 时间轴可视窗口 -> 素材时间窗口（片段的素材入点是 clip.start，在时间轴上却从累加时长处开始）
        let tlStart = max(0, Double(offset - ins) / pps)
        let tlEnd = Double(offset + width - ins) / pps
        var assetLow = Double.greatestFiniteMagnitude
        var assetHigh = -Double.greatestFiniteMagnitude
        var cursor = 0.0
        for clip in clips {
            let slotStart = cursor
            let slotEnd = cursor + clip.duration
            cursor = slotEnd
            let from = max(tlStart, slotStart)
            let to = min(tlEnd, slotEnd)
            guard to > from else { continue }
            assetLow = min(assetLow, clip.start + (from - slotStart))
            assetHigh = max(assetHigh, clip.start + (to - slotStart))
        }
        visibleStartTime = assetHigh > assetLow ? assetLow : tlStart
        visibleEndTime = assetHigh > assetLow ? assetHigh : tlEnd
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
    /// 这里自己开关容差，不能用 core 那张「无限容差取最近关键帧」的流式接口，
    /// 否则长 GOP 的视频会整条胶片都变成同一帧。
    private func generateFilmstrip(generationID: Int) async {
        guard let source, assetDuration > 0.1, timelineViewportWidth > 1 else { return }
        let interval = thumbnailInterval
        let margin = max(2 * Double(timelineViewportWidth) / pps, 5)
        let startT = max(0, visibleStartTime - margin)
        let endT = min(assetDuration, visibleEndTime + margin)
        let first = Int(floor(startT / interval))
        let last = Int(ceil(endT / interval))
        guard last > first, last - first <= 900 else { return }
        // 只补「没有缓存、也不在飞行中」的槽位：滚动时同一批帧不会重复取
        let slots = (first..<last).filter { filmstrip[$0] == nil && !pendingSlots.contains($0) }
        guard !slots.isEmpty else { return }
        pendingSlots.formUnion(slots)

        let asset = self.asset ?? AVURLAsset(url: source.url)
        var times: [NSValue] = []
        var indexByKey: [String: Int] = [:]
        let lastSlot = last - 1
        for slot in slots {
            // 最后一格：整段除不尽时按视频末帧补，避免尾部出现空格
            var seconds = Double(slot) * interval
            if slot == lastSlot, seconds > assetDuration - 0.05 {
                seconds = max(assetDuration - 0.04, 0)
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 1800)
            indexByKey["\(time.value)-\(time.timescale)"] = slot
            times.append(NSValue(time: time))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        // 间隔可以细到 1/30s，容差跟着缩，避免相邻帧取重
        let tolerance = CMTime(seconds: min(0.05, interval / 3), preferredTimescale: 1800)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        filmstripGenerator = generator

        defer { flushFrames() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var remaining = times.count
            generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
                let key = "\(requested.value)-\(requested.timescale)"
                if let slot = indexByKey[key] {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pendingSlots.remove(slot)
                        guard self.filmstripGenerationID == generationID, let image else { return }
                        // 先入缓冲，40ms 批量提交，一次滚动只重绘几次而不是几十次
                        self.frameBuffer[slot] = image
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
        for (slot, image) in frameBuffer { merged[slot] = image }
        frameBuffer.removeAll()
        filmstrip = merged
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
        let oldInterval = thumbnailInterval
        clips = previous
        canUndo = !undoStack.isEmpty
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        saveDraft()
    }

    /// 重置：整条原片一段
    func resetTimeline() {
        pushUndo()
        clips = [MacClip(start: 0, end: assetDuration)]
        rebuildComposition(preserveTime: 0)
        saveDraft()
    }

    /// 退回空项目（V2.8.5）：项目里正在编辑的那条素材被删掉时，时间轴、播放器一起清空
    func clearProject() {
        pause()
        source = nil
        clips = []
        outputDuration = 0
        currentTime = 0
        undoStack.removeAll()
        canUndo = false
        isClipSelected = false
        asset = nil
        assetDuration = 0
        videoTrack = nil
        audioTrack = nil
        audioTimeRange = .zero
        transform = .identity
        filmstrip = [:]
        filmstripInterval = 0
        pendingSlots.removeAll()
        frameBuffer.removeAll()
        filmstripTask?.cancel()
        player.replaceCurrentItem(with: nil)
    }

    /// 在播放头处把当前片段切成两段
    func splitAtPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        // 播放头正好压在片段端点（比如刚在这一刀切过）什么都不做，不弹提示
        guard anchor.sourceTime - clip.start > 0.05, clip.end - anchor.sourceTime > 0.05 else { return }
        pushUndo()
        // V2.7.13：左段沿用原 id，右段新建，切割只重画右段，不整条闪
        clips[anchor.index] = MacClip(id: clip.id, start: clip.start, end: anchor.sourceTime)
        clips.insert(MacClip(start: anchor.sourceTime, end: clip.end), at: anchor.index + 1)
        rebuildComposition(preserveTime: currentTime)
        saveDraft()
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

    /// 删除播放头所在的片段；删到一段不剩就回到「素材拖进来」的空状态
    func deleteClipAtPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips.remove(at: anchor.index)
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        saveDraft()
    }

    /// 向左裁剪（V2.7.17）：只裁「选中这一段」——把它从播放头处切掉左半，右半接着用，
    /// 前面、后面的片段一根汗毛都不动；播放指针停在（裁完后）这一段的起点。
    func trimBeforePlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard anchor.sourceTime - clip.start > 0.02 else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips[anchor.index] = MacClip(id: clip.id, start: anchor.sourceTime, end: clip.end)
        // 播放头对准这一段的起点：它前面所有片段的时长之和
        let head = clips[..<anchor.index].reduce(0) { $0 + $1.duration }
        rebuildComposition(preserveTime: head)
        keepScale(oldInterval)
        saveDraft()
    }

    /// 向右裁剪（V2.7.17）：同样只裁「选中这一段」——从播放头处切掉右半，
    /// 后面的片段原地保留（整体往前接上）；播放指针停在原处（新的段末）。
    func trimAfterPlayhead() {
        guard let anchor = clipAt(currentTime) else { return }
        let clip = clips[anchor.index]
        guard clip.end - anchor.sourceTime > 0.02 else { return }
        let oldInterval = thumbnailInterval
        pushUndo()
        clips[anchor.index] = MacClip(id: clip.id, start: clip.start, end: anchor.sourceTime)
        rebuildComposition(preserveTime: currentTime)
        keepScale(oldInterval)
        saveDraft()
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

        // 用片段时长求和而不是 CMTime 取整后的结果：切割前后总长严格相等，
        // 缩略图间隔不会因为几微秒的取整误差被判成「换档」，胶片就不会整块重取
        outputDuration = max(clips.reduce(0) { $0 + $1.duration }, 0)
        let target = min(max(preserveTime ?? 0, 0), max(0, outputDuration - 0.02))
        isRebuildingPlayer = true
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
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

    // MARK: - 草稿 / 导出

    func saveDraft() {
        guard let videoID = source?.libraryVideoID else { return }
        guard !clips.isEmpty else {
            MacEditorDraftStore.clear(for: videoID)
            return
        }
        MacEditorDraftStore.save(
            MacEditorDraft(
            clips: clips,
            isMuted: isMuted,
            updatedAt: Date(),
            currentTime: currentTime,
            zoomLevel: zoomLevel
        ),
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
    /// 项目素材（V2.8.5）：编辑页导入过的视频列表，独立于素材库
    @State private var projectMaterials: [MacProjectMaterial] = []
    /// 每条素材的首帧缩略图缓存
    @State private var materialThumbnails: [UUID: CGImage] = [:]
    /// 素材区里选中的素材（V2.8.5：支持 ⌘ 多选后删除）
    @State private var selectedMaterialIDs: Set<UUID> = []
    /// 导出进度弹框
    @State private var isExportSheetPresented = false
    /// 导出失败文案（弹框内展示，不走全局 alert）
    @State private var exportErrorText: String?

    init(initialSource: MacEditorSource?) {
        _model = StateObject(wrappedValue: MacEditorModel(source: initialSource))
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
            seedInitialMaterialIfNeeded()
        }        .onDisappear { model.saveDraft() }
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
            Text(model.source?.title ?? "新建编辑")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if model.source == nil {
                Text("空白项目")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MacTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MacTheme.accent.opacity(0.14), in: Capsule())
            }

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
                    ForEach(projectMaterials) { material in
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
        let loaded = model.source?.id == material.id
        let picked = selectedMaterialIDs.contains(material.id)
        return Button {
            handleMaterialTap(material)
        } label: {
        VStack(alignment: .leading, spacing: 7) {
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
                        picked ? Color.white : (loaded ? MacTheme.accent : Color.white.opacity(0.06)),
                        lineWidth: picked ? 2.5 : (loaded ? 2 : 1)
                    )
            )

            Text(material.title)
                .font(.caption)
                .foregroundStyle(picked || loaded ? Color.white : Color.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .padding(2)
        .background(
            picked ? Color.white.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        }
        .buttonStyle(.plain)
        .help("点一下载进时间轴，⌘ 点选可多选，Delete 键删除")
    }

    /// 正方形首帧缩略图（取不到就显示占位图标）
    @ViewBuilder
    private func materialThumbnail(_ material: MacProjectMaterial) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image = materialThumbnails[material.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
        .task(id: material.id) {
            loadThumbnail(for: material)
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

    /// 点 cell：⌘ 点击切换多选；普通点击选中并载进时间轴
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
        guard model.source?.id != material.id else { return }
        Task { await model.open(MacEditorSource(id: material.id, url: material.url, title: material.title, libraryVideoID: nil)) }
    }

    private func confirmDeleteSelectedMaterials() {
        guard !selectedMaterialIDs.isEmpty else { return }
        deleteSelectedMaterials()
    }

    /// 删素材：只从项目里移除，不动磁盘文件；删到正在编辑的那条就把时间轴清空
    private func deleteSelectedMaterials() {
        let ids = selectedMaterialIDs
        guard !ids.isEmpty else { return }
        let removesLoaded = model.source.map { ids.contains($0.id) } ?? false
        projectMaterials.removeAll { ids.contains($0.id) }
        for id in ids {
            materialThumbnails[id] = nil
        }
        selectedMaterialIDs.removeAll()
        if removesLoaded {
            model.clearProject()
        }
    }

    /// 首帧缩略图：异步取 0 秒那一帧，生成后回主线程塞进缓存
    private func loadThumbnail(for material: MacProjectMaterial) {
        guard materialThumbnails[material.id] == nil else { return }
        let id = material.id
        let url = material.url
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let frame = try? await generator.image(at: .zero) {
                materialThumbnails[id] = frame.image
            }
        }
    }

    // MARK: - 编辑区

    private var editingPanel: some View {
        VStack(spacing: 0) {
            if model.hasSource && !model.clips.isEmpty {
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
                .disabled(!model.hasSource)
                .opacity(model.hasSource ? 1 : 0.40)

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
                Text("点左侧「添加视频」载入素材，开始你的大作吧～")
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
                if model.hasSource {
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
                .opacity(model.hasSource && !model.isExporting ? 1 : 0.45)
            }
            .buttonStyle(.plain)
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
        loadLocalVideo(from: url)
    }

    /// 把选中的本地文件拷成临时文件，加进项目素材列表并载进时间轴（不写素材库）
    private func loadLocalVideo(from url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                let temp = try VideoImporter.prepare(from: url)
                let duration = await VideoImporter.duration(of: temp)
                let material = MacProjectMaterial(id: UUID(), url: temp, title: title, duration: duration)
                projectMaterials.append(material)
                selectedMaterialIDs = [material.id]
                loadThumbnail(for: material)
                await model.open(
                    MacEditorSource(id: material.id, url: temp, title: title, libraryVideoID: nil)
                )
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    /// 从「最近编辑」等入口带素材进来的窗口，把这条素材放进列表（首帧缩略图照旧现取）
    private func seedInitialMaterialIfNeeded() {
        guard let source = model.source else { return }
        guard !projectMaterials.contains(where: { $0.id == source.id }) else { return }
        let material = MacProjectMaterial(
            id: source.id,
            url: source.url,
            title: source.title,
            duration: model.outputDuration
        )
        projectMaterials = [material] + projectMaterials
        loadThumbnail(for: material)
    }

    // MARK: - 导出（V2.8.0 起带进度弹框，默认落到「下载」文件夹）

    /// 点导出：先把弹框顶上来，再在后台渲染时间轴，进度实时写进 model.exportProgress
    private func startExport() {
        guard model.hasSource, !model.clips.isEmpty, !model.isExporting else { return }
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
        let base = (model.source?.title ?? "clip").replacingOccurrences(of: "/", with: "-")
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

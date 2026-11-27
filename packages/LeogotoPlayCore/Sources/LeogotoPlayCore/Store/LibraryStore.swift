import AVFoundation
import Combine
import Foundation

/// 素材库核心 Store：文件夹 / 视频的增删改查、导入落盘、持久化。
@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var folders: [VideoFolder] = []
    @Published public private(set) var videos: [VideoItem] = []
    @Published public private(set) var isImporting = false
    @Published public var lastErrorMessage: String?

    private let files = VideoFileStore.shared
    private var saveTask: Task<Void, Never>?

    public init(loadFromDisk: Bool = true) {
        if loadFromDisk { load() }
    }

    // MARK: - 查询

    public func videos(in folderID: UUID?) -> [VideoItem] {
        videos
            .filter { $0.folderID == folderID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var uncategorizedVideos: [VideoItem] { videos(in: nil) }

    public func videoCount(in folderID: UUID) -> Int {
        videos.filter { $0.folderID == folderID }.count
    }

    public func coverThumbnails(for folderID: UUID, limit: Int = 3) -> [String?] {
        videos
            .filter { $0.folderID == folderID }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0.thumbnailName }
    }

    public var recentVideos: [VideoItem] {
        Array(videos.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8))
    }

    public var totalSize: Int64 { videos.reduce(into: Int64(0)) { $0 += $1.fileSize } }
    public var totalDuration: Double { videos.reduce(0) { $0 + $1.duration } }

    public func folder(with id: UUID?) -> VideoFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    // MARK: - 文件夹层级（V1.0.3）

    /// 根目录下的文件夹（`parentID == nil`）。
    public var rootFolders: [VideoFolder] {
        sortedFolders { $0.parentID == nil }
    }

    /// 指定文件夹下的子文件夹；传 nil 等于根目录。
    public func subfolders(in parentID: UUID?) -> [VideoFolder] {
        sortedFolders { $0.parentID == parentID }
    }

    public func subfolderCount(in parentID: UUID) -> Int {
        folders.filter { $0.parentID == parentID }.count
    }

    /// 从根到当前文件夹的路径，例如「旅行 / 日本」。
    public func folderPath(for folderID: UUID, separator: String = " / ") -> String {
        var parts: [String] = []
        var cursor: VideoFolder? = folder(with: folderID)
        var guardCount = 0
        while let current = cursor, guardCount < 64 {
            parts.insert(current.name, at: 0)
            cursor = folder(with: current.parentID)
            guardCount += 1
        }
        return parts.joined(separator: separator)
    }

    /// 某文件夹的全部后代文件夹（含多层）。
    public func descendantFolderIDs(of folderID: UUID) -> [UUID] {
        var result: [UUID] = []
        var queue: [UUID] = [folderID]
        var guardCount = 0
        while let current = queue.popLast(), guardCount < 4096 {
            let children = folders.filter { $0.parentID == current }.map(\.id)
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
            guardCount += 1
        }
        return result
    }

    /// 含所有子文件夹在内的视频总数。
    public func totalVideoCount(in folderID: UUID) -> Int {
        let ids = Set([folderID] + descendantFolderIDs(of: folderID))
        return videos.filter { item in
            guard let folderID = item.folderID else { return false }
            return ids.contains(folderID)
        }.count
    }

    private func sortedFolders(matching predicate: (VideoFolder) -> Bool) -> [VideoFolder] {
        folders.filter(predicate).sorted { $0.createdAt < $1.createdAt }
    }

    public func video(with id: UUID) -> VideoItem? {
        videos.first { $0.id == id }
    }

    /// 按标题搜索。
    public func searchVideos(keyword: String) -> [VideoItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return videos }
        return videos.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: - 文件夹

    @discardableResult
    public func createFolder(named name: String, parentID: UUID? = nil) -> VideoFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "文件夹名称不能为空"
            return nil
        }
        // 父文件夹必须真实存在，避免出现悬空节点
        let resolvedParent: UUID? = parentID.flatMap { self.folder(with: $0)?.id }
        let newFolder = VideoFolder(name: trimmed, parentID: resolvedParent)
        folders.append(newFolder)
        touchFolder(resolvedParent)
        persist()
        return newFolder
    }

    /// 把文件夹移到另一个父级下（`nil` = 根目录）。不允许移到自己或自己的子孙里。
    public func moveFolder(_ folderID: UUID, to parentID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        if let parentID {
            var cursor: UUID? = parentID
            var depth = 0
            while let current = cursor, depth < 128 {
                if current == folderID {
                    lastErrorMessage = "不能把文件夹移动到它自己或它的子文件夹里"
                    return
                }
                cursor = folder(with: current)?.parentID
                depth += 1
            }
        }
        folders[index].parentID = parentID
        folders[index].updatedAt = Date()
        touchFolder(folderID)
        touchFolder(parentID)
        persist()
    }

    public func renameFolder(_ folderID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = trimmed
        folders[index].updatedAt = Date()
        persist()
    }

    /// 删除文件夹：连同其所有子文件夹一起处理。
    /// `deleteVideos == true` 时删除子树里的全部视频文件，否则这些视频回到「未分类」。
    public func deleteFolder(_ folderID: UUID, deleteVideos: Bool) {
        guard folders.contains(where: { $0.id == folderID }) else { return }
        let parentID = folder(with: folderID)?.parentID
        let removedIDs = Set([folderID] + descendantFolderIDs(of: folderID))
        folders.removeAll { removedIDs.contains($0.id) }

        if deleteVideos {
            for item in videos {
                guard let target = item.folderID, removedIDs.contains(target) else { continue }
                files.deleteVideo(named: item.fileName)
                files.deleteThumbnail(named: item.thumbnailName)
            }
            videos.removeAll { item in
                guard let target = item.folderID else { return false }
                return removedIDs.contains(target)
            }
        } else {
            for i in videos.indices {
                if let target = videos[i].folderID, removedIDs.contains(target) {
                    videos[i].folderID = nil
                }
            }
        }
        touchFolder(parentID)
        persist()
    }

    // MARK: - 视频

    /// 导入一个临时文件到素材库，成功后返回入库的 VideoItem。
    @discardableResult
    public func importVideo(
        fromTempURL tempURL: URL,
        source: VideoSource,
        folderID: UUID? = nil,
        suggestedTitle: String? = nil
    ) async throws -> VideoItem {
        isImporting = true
        defer { isImporting = false }

        let fileName = files.makeFileName(fileExtension: tempURL.pathExtension)
        try files.copyVideo(from: tempURL, to: fileName)

        let storedURL = files.videoURL(for: fileName)
        // 入库前先确认文件真能读：没有视频轨 / 时长读不出来的一律拒绝，
        // 否则素材库里会出现一条点开黑屏、拖进剪辑页也导不出的坏记录。
        let hasVideoTrack = ((try? await AVURLAsset(url: storedURL)
            .loadTracks(withMediaType: .video))?.isEmpty == false)
        let duration = await VideoImporter.duration(of: storedURL)
        guard hasVideoTrack, duration.isFinite, duration > 0.01 else {
            files.deleteVideo(named: fileName)
            throw VideoImportError.unsupported
        }
        let size = files.fileSize(of: fileName)
        let thumbnail = await ThumbnailService.generateCover(forVideoAt: storedURL, at: 0)
        // 连封面都抽不出来的文件，基本都是坏文件（下载中断、导出被截断）；
        // 这种条目入库后就是黑屏 + 打不开，直接拒掉比留个坏记录好。
        guard let thumbnail else {
            files.deleteVideo(named: fileName)
            throw VideoImportError.unsupported
        }

        let item = VideoItem(
            title: suggestedTitle ?? Self.defaultTitle(),
            fileName: fileName,
            folderID: folderID,
            duration: duration,
            fileSize: size,
            source: source,
            thumbnailName: thumbnail
        )
        videos.insert(item, at: 0)
        touchFolder(folderID)
        persist()
        return item
    }

    /// 编辑器导出后「存入素材库」。
    @discardableResult
    public func importExport(fileURL: URL, title: String? = nil, folderID: UUID? = nil) async throws -> VideoItem {
        try await importVideo(fromTempURL: fileURL, source: .editor, folderID: folderID, suggestedTitle: title)
    }

    public func deleteVideo(_ videoID: UUID) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        let item = videos[index]
        files.deleteVideo(named: item.fileName)
        files.deleteThumbnail(named: item.thumbnailName)
        videos.remove(at: index)
        touchFolder(item.folderID)
        persist()
    }

    public func moveVideo(_ videoID: UUID, to folderID: UUID?) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        let oldFolder = videos[index].folderID
        videos[index].folderID = folderID
        videos[index].modifiedAt = Date()
        touchFolder(folderID)
        touchFolder(oldFolder)
        persist()
    }

    public func renameVideo(_ videoID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        videos[index].title = trimmed
        videos[index].modifiedAt = Date()
        persist()
    }

    public func toggleFavorite(_ videoID: UUID) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        videos[index].isFavorite.toggle()
        persist()
    }

    /// 剪辑完成 / 元数据变化时刷新。
    public func refreshMetadata(for videoID: UUID) async {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        let storedURL = files.videoURL(for: videos[index].fileName)
        let duration = await VideoImporter.duration(of: storedURL)
        if videos[index].thumbnailName == nil {
            videos[index].thumbnailName = await ThumbnailService.generateCover(forVideoAt: storedURL, at: 0)
        }
        videos[index].duration = duration
        videos[index].fileSize = files.fileSize(of: videos[index].fileName)
        videos[index].modifiedAt = Date()
        persist()
    }

    // MARK: - 存储

    public func clearThumbnailCache() {
        files.clearThumbnailCache()
    }

    private func touchFolder(_ folderID: UUID?) {
        guard let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].updatedAt = Date()
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "视频 \(formatter.string(from: Date()))"
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: files.libraryFileURL),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else {
            return
        }
        folders = snapshot.folders
        videos = snapshot.videos

        // 清理已不存在的文件（被外部清理 / 手动删除）
        let existing = videos.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if existing.count != videos.count {
            videos = existing
            persistNow()
        }
        backfillMissingThumbnails()
        migrateCoversToFirstFrame()
    }

    /// V2.7.16：历史封面取的是 1s 附近的帧。这里做一次性迁移，把所有封面重抽成第一帧，
    /// 素材墙里看到的就是视频开头那一画面（旧封面文件顺手删掉，避免沙盒里堆垃圾）。
    private func migrateCoversToFirstFrame() {
        let key = "leogotoplay.library.firstFrameCovers"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let items = videos
        guard !items.isEmpty else { return }
        Task { [weak self] in
            for item in items {
                guard let self else { return }
                let url = self.files.videoURL(for: item.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let name = await ThumbnailService.generateCover(forVideoAt: url, at: 0) else { continue }
                if let index = self.videos.firstIndex(where: { $0.id == item.id }) {
                    let old = self.videos[index].thumbnailName
                    self.videos[index].thumbnailName = name
                    if let old, old != name { self.files.deleteThumbnail(named: old) }
                }
            }
            self?.persistNow()
        }
    }

    /// 老数据 / 剪辑导出可能缺封面（或封面文件被清掉），这里异步补齐，列表里就不会出现灰底空块。
    private func backfillMissingThumbnails() {
        let missing = videos.filter { item in
            guard let name = item.thumbnailName else { return true }
            return !FileManager.default.fileExists(atPath: files.thumbnailURL(named: name).path)
        }
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            for item in missing {
                guard let self else { return }
                let url = self.files.videoURL(for: item.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let name = await ThumbnailService.generateCover(forVideoAt: url, at: 0) else { continue }
                if let index = self.videos.firstIndex(where: { $0.id == item.id }) {
                    self.videos[index].thumbnailName = name
                }
            }
            self?.persistNow()
        }
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        let snapshot = LibrarySnapshot(folders: folders, videos: videos)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: files.libraryFileURL, options: .atomic)
    }
}

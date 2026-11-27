import AppKit
import AVFoundation
import Foundation
import LeogotoPlayCore

/// 时间轴上的一个片段：某条素材里的 [start, end] 区间。
/// V2.8.6 起时间轴上可以有多条素材，片段用 sourceID 指回项目素材。
struct MacClip: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// 素材（MacProjectMaterial / MacProjectMaterialFile 的 id）
    var sourceID: UUID?
    var start: Double
    var end: Double
    /// 同一次拖入的一组素材共享同一个 group id：时间轴上组内无缝连成一条，
    /// 但每段仍是独立片段（可单独裁剪 / 分割 / 拖动）
    var groupID: UUID?

    var duration: Double { max(0, end - start) }
}

/// 缩略图槽位键（V2.8.6）：多素材时间轴里同一秒可能来自不同素材，
/// 所以缓存键必须带上片段 id，不能只按素材时间算槽位。
struct MacFilmKey: Hashable {
    var clipID: UUID
    var slot: Int
    /// V2.8.13：槽位间隔（毫秒）。每段的间隔 = 段时长 / 张数，裁剪后间隔会变，带上它避免复用旧帧
    var step: Int = 0

    static func token(_ step: Double) -> Int { Int((step * 1000).rounded()) }
}

/// macOS 剪辑草稿：V2.0~V2.8.5 的单素材现场（按视频库视频 id 存）。
/// V2.8.6 起现场改成整项目的 MacProjectRecord，这份只留着读旧数据做迁移。
struct MacEditorDraft: Codable, Equatable {
    var clips: [MacClip]
    var isMuted: Bool
    var updatedAt: Date
    /// 上次退出时播放头的位置（V2.7.12：从「最近编辑」进来要还原现场）
    var currentTime: Double?
    /// 上次退出时的缩放档位
    var zoomLevel: Double?

    var outputDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    init(
        clips: [MacClip],
        isMuted: Bool,
        updatedAt: Date,
        currentTime: Double? = nil,
        zoomLevel: Double? = nil
    ) {
        self.clips = clips
        self.isMuted = isMuted
        self.updatedAt = updatedAt
        self.currentTime = currentTime
        self.zoomLevel = zoomLevel
    }

    private enum CodingKeys: String, CodingKey {
        case clips, isMuted, updatedAt, currentTime, zoomLevel
        // V2.0 的旧草稿只有一条裁剪区间，读的时候降级成单片段
        case trimStart, trimEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        currentTime = try container.decodeIfPresent(Double.self, forKey: .currentTime)
        zoomLevel = try container.decodeIfPresent(Double.self, forKey: .zoomLevel)

        if let stored = try container.decodeIfPresent([MacClip].self, forKey: .clips), !stored.isEmpty {
            clips = stored
        } else {
            let start = try container.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
            let end = try container.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
            clips = [MacClip(start: start, end: end)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(currentTime, forKey: .currentTime)
        try container.encodeIfPresent(zoomLevel, forKey: .zoomLevel)
    }
}

enum MacEditorDraftStore {
    private static let storageKey = "leogotoplay.mac.editor.drafts"

    private static func all() -> [String: MacEditorDraft] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let drafts = try? JSONDecoder().decode([String: MacEditorDraft].self, from: data)
        else { return [:] }
        return drafts
    }

    private static func write(_ drafts: [String: MacEditorDraft]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func key(for id: UUID) -> String { id.uuidString }

    static func draft(for videoID: UUID) -> MacEditorDraft? {
        all()[key(for: videoID)]
    }

    static func save(_ draft: MacEditorDraft, for videoID: UUID) {
        var drafts = all()
        drafts[key(for: videoID)] = draft
        write(drafts)
    }

    static func clear(for videoID: UUID) {
        var drafts = all()
        drafts.removeValue(forKey: key(for: videoID))
        write(drafts)
    }
}

// MARK: - 项目存档（V2.8.6：多素材时间轴 + 最近编辑保留现场）

/// 项目里的一条素材。`fileName` 相对 `Projects/<项目 id>/`；以 `/` 开头的表示直接引用原路径
/// （从视频库视频进来的素材不复制文件）。
struct MacProjectMaterialFile: Codable, Equatable, Identifiable {
    var id: UUID
    var fileName: String
    var title: String
    var duration: Double
}

extension Notification.Name {
    /// 项目重命名：首页改名后，已经开着的编辑窗口跟着更新标题
    static let macProjectRenamed = Notification.Name("leogotoplay.mac.projectRenamed")
}

/// 一个剪辑项目的完整现场：素材清单 + 时间轴片段 + 播放状态。
struct MacProjectRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var materials: [MacProjectMaterialFile]
    var clips: [MacClip]
    var isMuted: Bool
    var currentTime: Double?
    var zoomLevel: Double?
    /// V2.8.14：缩略图间隔的基准时长（= 第一次拖进时间轴的那条视频的时长），旧存档没有就按首段时长算
    var filmAnchor: Double? = nil

    var outputDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// 首条素材的 id（最近编辑卡片用它找缩略图）
    var coverMaterialID: UUID? { materials.first?.id }
}

enum MacProjectStore {
    private static var dataRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LeogotoPlay", isDirectory: true)
    }

    static var projectsRoot: URL { dataRoot.appendingPathComponent("Projects", isDirectory: true) }
    static var thumbsRoot: URL { dataRoot.appendingPathComponent("ProjectThumbs", isDirectory: true) }
    private static var indexURL: URL { dataRoot.appendingPathComponent("projects.json") }

    private static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [dataRoot, projectsRoot, thumbsRoot] where !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func directory(for projectID: UUID) -> URL {
        projectsRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    static func materialURL(for file: MacProjectMaterialFile, projectID: UUID) -> URL {
        if file.fileName.hasPrefix("/") {
            return URL(fileURLWithPath: file.fileName)
        }
        return directory(for: projectID).appendingPathComponent(file.fileName)
    }

    static func thumbnailURL(for materialID: UUID) -> URL {
        thumbsRoot.appendingPathComponent("\(materialID.uuidString).jpg")
    }

    // MARK: 索引

    static func projects() -> [MacProjectRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([MacProjectRecord].self, from: data)
        else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 最近编辑只展示真正动过时间轴的项目
    static func recentProjects() -> [MacProjectRecord] {
        projects().filter { !$0.clips.isEmpty }
    }

    static func project(id: UUID) -> MacProjectRecord? {
        projects().first { $0.id == id }
    }

    /// 已经在剪的视频库视频（同一个文件只开一个项目）
    static func project(referencingFileAt path: String) -> MacProjectRecord? {
        projects().first { $0.materials.contains { $0.fileName == path } }
    }

    static func save(_ record: MacProjectRecord) {
        ensureDirectories()
        var list = projects()
        var updated = record
        updated.updatedAt = Date()
        if let index = list.firstIndex(where: { $0.id == record.id }) {
            list[index] = updated
        } else {
            list.append(updated)
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL)
    }

    static func remove(_ projectID: UUID) {
        var list = projects()
        let materials = list.first { $0.id == projectID }?.materials ?? []
        list.removeAll { $0.id == projectID }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: indexURL)
        }
        try? FileManager.default.removeItem(at: directory(for: projectID))
        for material in materials {
            try? FileManager.default.removeItem(at: thumbnailURL(for: material.id))
        }
    }

    /// 重命名（不刷新 updatedAt，避免首页按时间重排）
    static func rename(_ projectID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = projects()
        guard let index = list.firstIndex(where: { $0.id == projectID }) else { return }
        list[index].title = trimmed
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL)
        NotificationCenter.default.post(
            name: .macProjectRenamed,
            object: nil,
            userInfo: ["id": projectID, "title": trimmed]
        )
    }

    // MARK: 新建

    /// 新项目默认标题：`11-27 (01)` —— 「月-日」+ 当天第几个项目（两位，从 01 起）
    static func defaultTitle(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M-d"
        let prefix = formatter.string(from: date)

        // 已经用掉的最大编号（改名过的项目也保留它的号，避免和还叫旧名的撞号）
        var maxIndex = 0
        for record in projects() where record.title.hasPrefix(prefix + " (") && record.title.hasSuffix(")") {
            let digits = record.title.dropFirst(prefix.count + 2).dropLast()
            if let number = Int(digits) { maxIndex = max(maxIndex, number) }
        }
        // 当天新建过几个（含已改名的），编号从它的下一个开始
        let calendar = Calendar.current
        let todayCount = projects().filter { calendar.isDate($0.createdAt, inSameDayAs: date) }.count
        let next = max(maxIndex, todayCount) + 1
        return "\(prefix) (\(String(format: "%02d", next)))"
    }

    static func newBlankProject() -> MacProjectRecord {
        MacProjectRecord(
            id: UUID(),
            title: defaultTitle(),
            createdAt: Date(),
            updatedAt: Date(),
            materials: [],
            clips: [],
            isMuted: false,
            currentTime: nil,
            zoomLevel: nil
        )
    }

    /// 视频库视频进剪辑：一条引用原文件的素材；旧单素材草稿迁移成片段表
    static func newProject(libraryFile url: URL, title: String, videoID: UUID) -> MacProjectRecord {
        let duration = MacEditorDraftStore.draft(for: videoID)?.clips.reduce(0) { $0 + $1.duration } ?? 0
        let material = MacProjectMaterialFile(
            id: videoID,
            fileName: url.path,
            title: title,
            duration: duration
        )
        var clips: [MacClip] = []
        if let draft = MacEditorDraftStore.draft(for: videoID), !draft.clips.isEmpty {
            clips = draft.clips.map { MacClip(sourceID: videoID, start: $0.start, end: $0.end) }
        } else {
            clips = [MacClip(sourceID: videoID, start: 0, end: duration)]
        }
        return MacProjectRecord(
            id: UUID(),
            title: defaultTitle(),
            createdAt: Date(),
            updatedAt: Date(),
            materials: [material],
            clips: clips,
            isMuted: MacEditorDraftStore.draft(for: videoID)?.isMuted ?? false,
            currentTime: MacEditorDraftStore.draft(for: videoID)?.currentTime,
            zoomLevel: MacEditorDraftStore.draft(for: videoID)?.zoomLevel
        )
    }

    // MARK: 素材文件

    /// 导入一条本地视频到项目目录（拷文件、取时长、顺手存一张首帧缩略图）
    static func importMaterial(from url: URL, into projectID: UUID) async throws -> MacProjectMaterialFile {
        ensureDirectories()
        let dir = directory(for: projectID)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        let title = url.deletingPathExtension().lastPathComponent
        let duration = await VideoImporter.duration(of: destination)
        ensureThumbnail(for: id, url: destination)
        return MacProjectMaterialFile(id: id, fileName: fileName, title: title, duration: duration)
    }

    // MARK: 缩略图（首帧）

    static func thumbnail(for materialID: UUID) -> NSImage? {
        guard let image = NSImage(contentsOf: thumbnailURL(for: materialID)) else { return nil }
        return image
    }

    static func writeThumbnail(_ image: CGImage, for materialID: UUID) {
        ensureDirectories()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return }
        try? data.write(to: thumbnailURL(for: materialID))
    }

    /// 没有缩略图就补一张首帧（异步，失败就算了）
    static func ensureThumbnail(for materialID: UUID, url: URL) {
        guard !FileManager.default.fileExists(atPath: thumbnailURL(for: materialID).path) else { return }
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let frame = try? await generator.image(at: .zero) {
                writeThumbnail(frame.image, for: materialID)
            }
        }
    }
}

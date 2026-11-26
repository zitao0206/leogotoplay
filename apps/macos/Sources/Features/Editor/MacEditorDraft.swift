import Foundation

/// 时间轴上的一个片段：源视频里的 [start, end] 区间。
struct MacClip: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

/// macOS 剪辑草稿：离开剪辑页时把片段表（时间轴现场）和静音状态留在本机。
/// 只有素材库里的视频才有草稿（从文件临时导入的片子没有稳定 id，存不住）。
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

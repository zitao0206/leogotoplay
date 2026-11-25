import Foundation

/// macOS 剪辑草稿：离开剪辑页时把裁剪区间和静音状态留在本机。
/// 只有素材库里的视频才有草稿（从文件临时导入的片子没有稳定 id，存不住）。
struct MacEditorDraft: Codable, Equatable {
    var trimStart: Double
    var trimEnd: Double
    var isMuted: Bool
    var updatedAt: Date

    /// 草稿对应的成片时长，用来在「最近编辑」卡片上标时长
    var outputDuration: Double { max(0, trimEnd - trimStart) }
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

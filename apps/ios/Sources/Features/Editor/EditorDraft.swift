import Foundation
import LeogotoPlayCore

/// V4.0：剪辑草稿。
///
/// 把用户离开剪辑页时的现场（分段区间、每段的倍速/音量、播放头位置）存到本机，
/// 下次从「最近编辑」点同一个视频回来，就直接还原到那一刻，而不是一条从头开始的完整片段。
/// 只有视频库里的视频才有草稿（相册/文件的临时视频离开就删，没地方存）。
struct EditorDraft: Codable, Equatable {
    struct ClipData: Codable, Equatable {
        var start: Double
        var end: Double
        var speed: Double
        var volume: Double
    }

    var clips: [ClipData]
    var playhead: Double
    var isAspectFill: Bool
    var updatedAt: Date

    /// 成片时长，用来在「最近编辑」卡片上标草稿的时长
    var outputDuration: Double {
        clips.reduce(0) { $0 + max(0, $1.end - $1.start) / max($1.speed, 0.01) }
    }
}

enum EditorDraftStore {
    private static let storageKey = "leogotoplay.editor.drafts"

    private static func all() -> [String: EditorDraft] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let drafts = try? JSONDecoder().decode([String: EditorDraft].self, from: data)
        else { return [:] }
        return drafts
    }

    private static func write(_ drafts: [String: EditorDraft]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func key(for id: UUID) -> String { id.uuidString }

    static func draft(for item: VideoItem) -> EditorDraft? {
        all()[key(for: item.id)]
    }

    static func hasDraft(for item: VideoItem) -> Bool {
        draft(for: item) != nil
    }

    static func save(_ draft: EditorDraft, for item: VideoItem) {
        var drafts = all()
        drafts[key(for: item.id)] = draft
        write(drafts)
    }

    static func clear(for item: VideoItem) {
        var drafts = all()
        drafts.removeValue(forKey: key(for: item.id))
        write(drafts)
    }
}

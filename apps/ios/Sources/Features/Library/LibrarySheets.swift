import SwiftUI
import LeogotoPlayCore

// MARK: - 通用文本输入弹窗

struct TextInputSheet: View {
    let title: String
    let placeholder: String
    let initialText: String
    let confirmTitle: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(
        title: String,
        placeholder: String,
        initialText: String = "",
        confirmTitle: String = "保存",
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initialText = initialText
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(confirm)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: confirm)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
    }

    private func confirm() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}

/// 文本编辑请求：新建文件夹 / 重命名视频 / 重命名文件夹复用同一个 sheet。
struct TextEditRequest: Identifiable {
    enum Kind {
        case newFolder
        case renameVideo(VideoItem)
        case renameFolder(VideoFolder)
    }

    let id = UUID()
    let kind: Kind
    /// 新建文件夹时的上级目录；nil 表示建在视频库根目录。
    var parentID: UUID?

    init(kind: Kind, parentID: UUID? = nil) {
        self.kind = kind
        self.parentID = parentID
    }

    var title: String {
        switch kind {
        case .newFolder: return parentID == nil ? "新建文件夹" : "新建子文件夹"
        case .renameVideo: return "重命名视频"
        case .renameFolder: return "重命名文件夹"
        }
    }

    var placeholder: String {
        switch kind {
        case .newFolder: return parentID == nil ? "例如：旅行、娃、工作" : "例如：第一天、花絮"
        case .renameVideo, .renameFolder: return "输入名称"
        }
    }

    var initialText: String {
        switch kind {
        case .newFolder: return ""
        case .renameVideo(let item): return item.title
        case .renameFolder(let folder): return folder.name
        }
    }

    var confirmTitle: String {
        switch kind {
        case .newFolder: return "创建"
        default: return "保存"
        }
    }
}

// MARK: - 移动到文件夹

struct MoveToFolderSheet: View {
    let folders: [VideoFolder]
    let currentFolderID: UUID?
    /// 文件夹在层级里的完整路径，嵌套文件夹靠它区分同名项。
    var pathProvider: ((UUID) -> String)? = nil
    let onMove: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(title: "未分类", folderID: nil)
                ForEach(folders) { folder in
                    row(title: pathProvider?(folder.id) ?? folder.name, folderID: folder.id)
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, folderID: UUID?) -> some View {
        Button {
            onMove(folderID)
            dismiss()
        } label: {
            HStack {
                Image(systemName: folderID == nil ? "tray" : "folder")
                    .foregroundStyle(folderID == nil ? Color.secondary : Theme.accent)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if currentFolderID == folderID {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

// MARK: - 删除确认

struct DeleteRequest: Identifiable {
    enum Kind {
        case video(VideoItem)
        case folder(VideoFolder)
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .video(let item): return "删除「\(item.title)」？"
        case .folder(let folder): return "删除文件夹「\(folder.name)」？"
        }
    }

    var message: String {
        switch kind {
        case .video: return "视频文件会从 App 视频库中移除，操作不可撤销。"
        case .folder: return "文件夹内的视频会回到「未分类」，视频文件不会被删除。"
        }
    }
}

// MARK: - 页面路由

/// 视频库页面里可能弹出的全屏页面。
enum LibraryRoute: Identifiable {
    case player(VideoItem)
    case editor(EditorViewModel.Source)

    var id: String {
        switch self {
        case .player(let item): return "player-\(item.id)"
        case .editor(let source): return "editor-\(source.id)"
        }
    }
}

// MARK: - 排序

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "最新导入"
        case .oldest: return "最早上传"
        case .name: return "按名称"
        case .size: return "按体积"
        }
    }
}

import SwiftUI
import LeogotoPlayCore

/// 重命名（文件夹 / 视频通用）。
struct MacRenameSheet: View {
    let title: String
    let currentName: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, currentName: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.currentName = currentName
        self.onCommit = onCommit
        _text = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(T("名称"), text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button(T("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(T("保存")) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

/// 移动到文件夹（含「未分类」）。
struct MacMoveSheet: View {
    let folders: [VideoFolder]
    let currentFolderID: UUID?
    var rootTitle: String = T("未分类")
    var title: String = T("移动到文件夹")
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                row(title: rootTitle, isCurrent: currentFolderID == nil) { onPick(nil) }
                ForEach(folders) { folder in
                    Divider()
                    row(title: folder.name, isCurrent: currentFolderID == folder.id) { onPick(folder.id) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            HStack {
                Spacer()
                Button(T("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func row(title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(MacTheme.accent.opacity(0.9))
                Text(title)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 新建文件夹。
struct MacNewFolderSheet: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("新建文件夹")).font(.headline)
            TextField(T("例如：旅行片段"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button(T("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(T("创建")) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

/// 删除文件夹：二选一（连带视频一起删 / 只删文件夹、视频留在根目录）。
struct MacFolderDeleteSheet: View {
    let folder: VideoFolder
    let videoCount: Int
    let onDeleteAll: () -> Void
    let onKeepVideos: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(T("删除文件夹「{1}」", folder.name))
                .font(.headline)

            Text(videoCount == 0
                 ? T("这个文件夹里没有视频，删除后不可恢复。")
                 : T("这个文件夹里有 {1} 个视频，选择怎么处理：", videoCount))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if videoCount > 0 {
                VStack(spacing: 8) {
                    actionRow(
                        title: T("删除文件夹和里面的视频"),
                        detail: T("{1} 个视频文件会一并从磁盘删除，不可恢复", videoCount),
                        symbol: "trash.fill",
                        tint: Color(red: 0.95, green: 0.32, blue: 0.28)
                    ) {
                        dismiss()
                        onDeleteAll()
                    }
                    actionRow(
                        title: T("只删文件夹，视频移到根目录"),
                        detail: T("文件夹删掉，{1} 个视频保留在未分类里", videoCount),
                        symbol: "arrow.up.right.square",
                        tint: MacTheme.accent
                    ) {
                        dismiss()
                        onKeepVideos()
                    }
                }
            } else {
                actionRow(
                    title: T("删除文件夹"),
                    detail: T("文件夹本身删除，不可恢复"),
                    symbol: "trash.fill",
                    tint: Color(red: 0.95, green: 0.32, blue: 0.28)
                ) {
                    dismiss()
                    onDeleteAll()
                }
            }

            HStack {
                Spacer()
                Button(T("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func actionRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(tint.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

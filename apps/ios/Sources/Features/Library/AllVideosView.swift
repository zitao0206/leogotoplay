import SwiftUI
import LeogotoPlayCore

/// V2.0.1：全部视频页面，以列表形式展示素材库中的所有视频。
struct AllVideosView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var sort: LibrarySort = .newest
    @State private var route: LibraryRoute?
    @State private var textEdit: TextEditRequest?
    @State private var moveTarget: VideoItem?
    @State private var pendingDelete: DeleteRequest?
    @State private var showDeleteDialog = false
    @State private var toastMessage: String?

    private var videos: [VideoItem] {
        switch sort {
        case .newest: return library.videos.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return library.videos.sorted { $0.createdAt < $1.createdAt }
        case .name: return library.videos.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .size: return library.videos.sorted { $0.fileSize > $1.fileSize }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if videos.isEmpty {
                    EmptyStateView(
                        symbol: "film.stack",
                        title: "素材库还是空的",
                        message: "回到 List 页，点右上角「相册」图标导入第一个视频，或从文件导入。"
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                } else {
                    ForEach(videos) { item in
                        Button {
                            route = .player(item)
                        } label: {
                            VideoListRow(
                                item: item,
                                folderPath: item.folderID.map { library.folderPath(for: $0) }
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            videoContextMenu(for: item)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)
            .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("全部视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(LibrarySort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .toast($toastMessage)
        .overlay {
            if library.isImporting {
                ProgressView()
            }
        }
        .sheet(item: $textEdit) { request in
            TextInputSheet(
                title: request.title,
                placeholder: request.placeholder,
                initialText: request.initialText,
                confirmTitle: request.confirmTitle
            ) { text in
                if case .renameVideo(let item) = request.kind {
                    library.renameVideo(item.id, to: text)
                    toastMessage = "已重命名"
                }
            }
        }
        .sheet(item: $moveTarget) { item in
            MoveToFolderSheet(
                folders: library.folders,
                currentFolderID: item.folderID,
                pathProvider: { library.folderPath(for: $0) }
            ) { folderID in
                library.moveVideo(item.id, to: folderID)
                toastMessage = "已移动到\(library.folder(with: folderID)?.name ?? "未分类")"
            }
        }
        .fullScreenCover(item: $route) { route in
            switch route {
            case .player(let item):
                VideoPlayerView(item: item)
                    .environmentObject(library)
            case .editor(let source):
                VideoEditorView(source: source)
                    .environmentObject(library)
            }
        }
        .confirmationDialog(
            pendingDelete?.title ?? "确认删除",
            isPresented: $showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("删除视频", role: .destructive) {
                if case .video(let item) = pendingDelete?.kind {
                    library.deleteVideo(item.id)
                    toastMessage = "视频已删除"
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.message ?? "")
        }
    }

    @ViewBuilder
    private func videoContextMenu(for item: VideoItem) -> some View {
        Button {
            route = .player(item)
        } label: {
            Label("播放", systemImage: "play.fill")
        }
        Button {
            route = .editor(.library(item))
        } label: {
            Label("剪辑", systemImage: "scissors")
        }
        Button {
            moveTarget = item
        } label: {
            Label("移动到文件夹", systemImage: "folder")
        }
        Button {
            textEdit = TextEditRequest(kind: .renameVideo(item))
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button(role: .destructive) {
            pendingDelete = DeleteRequest(kind: .video(item))
            showDeleteDialog = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

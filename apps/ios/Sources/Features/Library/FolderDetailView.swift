import SwiftUI
import LeogotoPlayCore

/// 文件夹详情：展示该文件夹下的视频，支持移动、重命名、删除。
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let folderID: UUID
    private let initialName: String

    @State private var textEdit: TextEditRequest?
    @State private var moveTarget: VideoItem?
    @State private var route: LibraryRoute?
    @State private var pendingDelete: DeleteRequest?
    @State private var showDeleteDialog = false
    @State private var toastMessage: String?

    init(folder: VideoFolder) {
        folderID = folder.id
        initialName = folder.name
    }

    private var folder: VideoFolder? { library.folder(with: folderID) }
    private var subfolders: [VideoFolder] { library.subfolders(in: folderID) }
    private var videos: [VideoItem] {
        library.videos(in: folderID).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsRow

                if !subfolders.isEmpty {
                    subfolderSection
                }

                if videos.isEmpty {
                    EmptyStateView(
                        symbol: "folder",
                        title: subfolders.isEmpty ? "这个文件夹还是空的" : "这个文件夹还没有视频",
                        message: "点右上角「+」可以在当前文件夹里再建子文件夹；视频则通过「移动到文件夹」收进来。"
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                } else {
                    // V1.0.3：视频统一用列表 cell（缩略图 + 名称.mp4 + 大小 / 日期 / 时长）。
                    LazyVStack(spacing: 8) {
                        ForEach(videos) { item in
                            Button {
                                route = .player(item)
                            } label: {
                                VideoListRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
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
                                    library.toggleFavorite(item.id)
                                } label: {
                                    Label(item.isFavorite ? "取消收藏" : "收藏",
                                          systemImage: item.isFavorite ? "heart.slash" : "heart")
                                }
                                Button {
                                    moveTarget = item
                                } label: {
                                    Label("移动 / 移出文件夹", systemImage: "folder")
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
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(folder?.name ?? initialName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // V1.0.3：进入文件夹后，右上角仍然保留「+」，用于在当前目录新建子文件夹。
                Button {
                    textEdit = TextEditRequest(kind: .newFolder, parentID: folderID)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("在当前文件夹新建子文件夹")

                Menu {
                    Button {
                        if let folder {
                            textEdit = TextEditRequest(kind: .renameFolder(folder))
                        }
                    } label: {
                        Label("重命名文件夹", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if let folder {
                            pendingDelete = DeleteRequest(kind: .folder(folder))
                            showDeleteDialog = true
                        }
                    } label: {
                        Label("删除文件夹", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .toast($toastMessage)
        .sheet(item: $textEdit) { request in
            TextInputSheet(
                title: request.title,
                placeholder: request.placeholder,
                initialText: request.initialText,
                confirmTitle: request.confirmTitle
            ) { text in
                switch request.kind {
                case .renameVideo(let item):
                    library.renameVideo(item.id, to: text)
                case .renameFolder:
                    library.renameFolder(folderID, to: text)
                case .newFolder:
                    library.createFolder(named: text, parentID: request.parentID ?? folderID)
                }
                toastMessage = "已保存"
            }
        }
        .sheet(item: $moveTarget) { item in
            MoveToFolderSheet(
                folders: library.folders,
                currentFolderID: item.folderID,
                pathProvider: { library.folderPath(for: $0) }
            ) { target in
                library.moveVideo(item.id, to: target)
                toastMessage = "已移动"
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
            if case .folder = pendingDelete?.kind {
                Button("删除文件夹和其中的视频", role: .destructive) {
                    library.deleteFolder(folderID, deleteVideos: true)
                    pendingDelete = nil
                    dismiss()
                }
                Button("仅删除文件夹（视频留在未分类）", role: .destructive) {
                    library.deleteFolder(folderID, deleteVideos: false)
                    pendingDelete = nil
                    dismiss()
                }
            } else {
                Button("删除视频", role: .destructive) {
                    if case .video(let item) = pendingDelete?.kind {
                        library.deleteVideo(item.id)
                    }
                    pendingDelete = nil
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.message ?? "")
        }
    }

    /// V1.0.3：当前文件夹下的子文件夹列表。
    private var subfolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "子文件夹", subtitle: "\(subfolders.count) 个")

            ForEach(subfolders) { sub in
                NavigationLink {
                    FolderDetailView(folder: sub)
                        .environmentObject(library)
                } label: {
                    FolderListRow(
                        folder: sub,
                        videoCount: library.videoCount(in: sub.id),
                        subfolderCount: library.subfolderCount(in: sub.id)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        textEdit = TextEditRequest(kind: .renameFolder(sub))
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = DeleteRequest(kind: .folder(sub))
                        showDeleteDialog = true
                    } label: {
                        Label("删除文件夹", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            StatItem(value: "\(videos.count)", title: "视频")
            Divider().frame(height: 24)
            StatItem(value: videos.reduce(Int64(0)) { $0 + $1.fileSize }.fileSizeText, title: "占用")
            Divider().frame(height: 24)
            StatItem(value: videos.reduce(0) { $0 + $1.duration }.timecode, title: "总时长")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

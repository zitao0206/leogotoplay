import PhotosUI
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
    @State private var photoItem: PhotosPickerItem?

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
                // V1.0.4：文件夹内不再显示统计卡。
                if !subfolders.isEmpty {
                    subfolderSection
                }

                // V1.0.5：只有「既没有子文件夹、也没有视频」才算空文件夹；
                // 已经有了子文件夹就不再提示空态，避免上面列着子文件夹、下面说"空"。
                if videos.isEmpty && subfolders.isEmpty {
                    EmptyStateView(
                        symbol: "folder",
                        title: "这是个空文件夹",
                        message: "点右上角「+」建子文件夹，点右侧相册图标可直接把视频添加到当前文件夹。"
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                } else if !videos.isEmpty {
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

                // V1.0.3：原来的文件夹操作菜单换成首页的「添加视频」，导入直接落到当前文件夹。
                if AppConfig.current.allowsPhotoImport {
                    PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("从相册添加视频到当前文件夹")
                }
            }
        }
        .overlay {
            if library.isImporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在导入…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { await importFromPhotos(item) }
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

    private func importFromPhotos(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            let url = try await VideoImporter.prepare(from: item)
            try await library.importVideo(fromTempURL: url, source: .photos, folderID: folderID)
            VideoImporter.cleanTemporaryFile(at: url)
            toastMessage = "已添加到「\(folder?.name ?? initialName)」"
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    /// V1.0.3：当前文件夹下的子文件夹列表。
    private var subfolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // V1.0.5：去掉「子文件夹」标题和数量，直接列目录。
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

}

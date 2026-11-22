import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// List 页：素材库。文件夹管理 + 视频网格 + 导入（相册 / 文件）+ 搜索排序。
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    private let config = AppConfig.current

    @State private var searchText = ""
    @State private var sort: LibrarySort = .newest
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var textEdit: TextEditRequest?
    @State private var moveTarget: VideoItem?
    @State private var route: LibraryRoute?
    @State private var pendingDelete: DeleteRequest?
    @State private var showDeleteDialog = false
    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsBar

                if searchText.isEmpty {
                    folderSection
                }

                videoSection
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("List")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索视频名称")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        textEdit = TextEditRequest(kind: .newFolder)
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    if config.allowsFileImport {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从文件导入", systemImage: "doc.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if config.allowsPhotoImport {
                    PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("从相册导入")
                }
            }
        }
        .toast($toastMessage)
        .overlay {
            if library.isImporting {
                importOverlay
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { await importFromPhotos(item) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            importFromFiles(result)
        }
        .sheet(item: $textEdit) { request in
            TextInputSheet(
                title: request.title,
                placeholder: request.placeholder,
                initialText: request.initialText,
                confirmTitle: request.confirmTitle
            ) { text in
                applyTextEdit(request, text: text)
            }
        }
        .sheet(item: $moveTarget) { item in
            MoveToFolderSheet(
                folders: library.folders,
                currentFolderID: item.folderID
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
            if case .folder = pendingDelete?.kind {
                Button("删除文件夹和其中的视频", role: .destructive) {
                    if case .folder(let folder) = pendingDelete?.kind {
                        library.deleteFolder(folder.id, deleteVideos: true)
                        toastMessage = "已删除文件夹及其视频"
                    }
                    pendingDelete = nil
                }
                Button("仅删除文件夹（视频留在未分类）", role: .destructive) {
                    if case .folder(let folder) = pendingDelete?.kind {
                        library.deleteFolder(folder.id, deleteVideos: false)
                        toastMessage = "文件夹已删除，视频已归入未分类"
                    }
                    pendingDelete = nil
                }
            } else {
                Button("删除视频", role: .destructive) {
                    if case .video(let item) = pendingDelete?.kind {
                        library.deleteVideo(item.id)
                        toastMessage = "视频已删除"
                    }
                    pendingDelete = nil
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.message ?? "")
        }
    }

    // MARK: - 统计

    private var statsBar: some View {
        HStack(spacing: 0) {
            StatItem(value: "\(library.videos.count)", title: "视频")
            Divider().frame(height: 26)
            StatItem(value: "\(library.folders.count)", title: "文件夹")
            Divider().frame(height: 26)
            StatItem(value: library.totalSize.fileSizeText, title: "占用")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 文件夹

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "文件夹", subtitle: "把不同项目的素材分开收纳")
                Spacer()
                Button("新建") {
                    textEdit = TextEditRequest(kind: .newFolder)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                Button {
                    textEdit = TextEditRequest(kind: .newFolder)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                        Text("新建文件夹")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 116)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    )
                }
                .buttonStyle(.plain)

                ForEach(library.folders) { folder in
                    NavigationLink {
                        FolderDetailView(folder: folder)
                            .environmentObject(library)
                    } label: {
                        FolderCard(
                            folder: folder,
                            videoCount: library.videoCount(in: folder.id),
                            coverThumbnails: library.coverThumbnails(for: folder.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            textEdit = TextEditRequest(kind: .renameFolder(folder))
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDelete = DeleteRequest(kind: .folder(folder))
                            showDeleteDialog = true
                        } label: {
                            Label("删除文件夹", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 视频

    private var displayedVideos: [VideoItem] {
        let base = searchText.isEmpty ? library.videos : library.searchVideos(keyword: searchText)
        switch sort {
        case .newest: return base.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return base.sorted { $0.createdAt < $1.createdAt }
        case .name: return base.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .size: return base.sorted { $0.fileSize > $1.fileSize }
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: searchText.isEmpty ? "全部视频" : "搜索结果",
                    subtitle: "\(displayedVideos.count) 个 · \(displayedVideos.reduce(Int64(0)) { $0 + $1.fileSize }.fileSizeText)"
                )
                Spacer()
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

            if displayedVideos.isEmpty {
                EmptyStateView(
                    symbol: searchText.isEmpty ? "film.stack" : "magnifyingglass",
                    title: searchText.isEmpty ? "素材库还是空的" : "没有找到匹配的视频",
                    message: searchText.isEmpty
                        ? "点右上角「相册」图标导入第一个视频，或从文件导入。"
                        : "换个关键词试试，或者清空搜索条件。"
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(displayedVideos) { item in
                        Button {
                            route = .player(item)
                        } label: {
                            VideoCard(
                                item: item,
                                showsFolderName: true,
                                folderName: library.folder(with: item.folderID)?.name
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            videoContextMenu(for: item)
                        }
                    }
                }
            }
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
            library.toggleFavorite(item.id)
        } label: {
            Label(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.slash" : "heart")
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

    // MARK: - 导入

    private var importOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在导入…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func importFromPhotos(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            let url = try await VideoImporter.prepare(from: item)
            try await library.importVideo(fromTempURL: url, source: .photos)
            VideoImporter.cleanTemporaryFile(at: url)
            toastMessage = "已导入素材库"
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func importFromFiles(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let tempURL = try VideoImporter.prepare(from: url)
            let title = url.deletingPathExtension().lastPathComponent
            Task {
                do {
                    try await library.importVideo(fromTempURL: tempURL, source: .files, suggestedTitle: title)
                    toastMessage = "已导入素材库"
                } catch {
                    toastMessage = error.localizedDescription
                }
                VideoImporter.cleanTemporaryFile(at: tempURL)
            }
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    // MARK: - 文本编辑

    private func applyTextEdit(_ request: TextEditRequest, text: String) {
        switch request.kind {
        case .newFolder:
            library.createFolder(named: text)
            toastMessage = "已创建文件夹「\(text)」"
        case .renameVideo(let item):
            library.renameVideo(item.id, to: text)
            toastMessage = "已重命名"
        case .renameFolder(let folder):
            library.renameFolder(folder.id, to: text)
            toastMessage = "已重命名文件夹"
        }
    }
}

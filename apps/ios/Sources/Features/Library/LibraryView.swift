import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// List 页：素材库。文件夹管理 + 导入（相册 / 文件）+ 搜索。V2.0.1：
/// - 移除首页的「全部视频」卡片网格，改为 All -> 进入列表形式的全量视频页
/// - 文件夹视图支持 列表（默认）/ 卡片 两种形式切换
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    private let config = AppConfig.current

    /// 文件夹的展示形式；V2.0.1 起默认列表。
    enum FolderViewMode {
        case list
        case grid
    }

    @State private var folderViewMode: FolderViewMode = .list
    @State private var searchText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var textEdit: TextEditRequest?
    @State private var moveTarget: VideoItem?
    @State private var route: LibraryRoute?
    @State private var pendingDelete: DeleteRequest?
    @State private var showDeleteDialog = false
    @State private var toastMessage: String?
    // 仅 Debug：`-openFirstFolder YES` 直接进第一个根文件夹，方便截图核对目录内工具栏。
    @State private var debugFolder: VideoFolder?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsBar

                if searchText.isEmpty {
                    folderSection
                } else {
                    searchResultsSection
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background(debugFolderLink)
        .navigationTitle("List")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索视频名称")
        .toolbar {
            // V1.0.3：顶部只保留「+」，并且移到右上角，只负责新建文件夹。
            ToolbarItemGroup(placement: .topBarTrailing) {
                if config.allowsPhotoImport {
                    PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("从相册导入")
                }

                Button {
                    textEdit = TextEditRequest(kind: .newFolder, parentID: nil)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("在素材库根目录新建文件夹")
            }
        }
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "openFirstFolder"), debugFolder == nil {
                debugFolder = library.rootFolders.first
            }
            #endif
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

                // V2.0.1：视图切换键（列表 <-> 卡片），在 All 的左边
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        folderViewMode = folderViewMode == .list ? .grid : .list
                    }
                } label: {
                    Image(systemName: folderViewMode == .list ? "square.grid.2x2" : "list.bullet")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel(folderViewMode == .list ? "切换到卡片视图" : "切换到列表视图")

                // V2.0.1：原来的「新建」改为 All ->，进入全部视频页面
                NavigationLink {
                    AllVideosView()
                        .environmentObject(library)
                } label: {
                    HStack(spacing: 2) {
                        Text("All")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.top, 4)

            switch folderViewMode {
            case .list:
                folderList
            case .grid:
                folderGrid
            }
        }
    }

    /// 仅 Debug 用的隐藏跳转。
    private var debugFolderLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { debugFolder != nil },
                set: { if !$0 { debugFolder = nil } }
            )
        ) {
            if let folder = debugFolder {
                FolderDetailView(folder: folder)
                    .environmentObject(library)
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }

    /// V2.0.1：文件夹的列表形式（默认）。V2.0.2：移除顶部的新建文件夹 Cell。
    private var folderList: some View {
        VStack(spacing: 8) {
            ForEach(library.rootFolders) { folder in
                NavigationLink {
                    FolderDetailView(folder: folder)
                        .environmentObject(library)
                } label: {
                    FolderListRow(
                        folder: folder,
                        videoCount: library.videoCount(in: folder.id),
                        subfolderCount: library.subfolderCount(in: folder.id)
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

    /// V2.0.1：文件夹的卡片形式（原有的网格，作为第二种视图保留）。
    private var folderGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(library.rootFolders) { folder in
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

    // MARK: - 搜索结果

    private var searchResults: [VideoItem] {
        library.searchVideos(keyword: searchText)
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "搜索结果",
                subtitle: "\(searchResults.count) 个 · \(searchResults.reduce(Int64(0)) { $0 + $1.fileSize }.fileSizeText)"
            )

            if searchResults.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "没有找到匹配的视频",
                    message: "换个关键词试试，或者清空搜索条件。"
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(searchResults) { item in
                        Button {
                            route = .player(item)
                        } label: {
                            VideoListRow(
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

    // MARK: - 文本编辑

    private func applyTextEdit(_ request: TextEditRequest, text: String) {
        switch request.kind {
        case .newFolder:
            library.createFolder(named: text, parentID: request.parentID)
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

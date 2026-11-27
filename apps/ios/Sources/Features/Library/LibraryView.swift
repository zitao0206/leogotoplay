import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// Library 页：素材库。文件夹管理 + 导入（相册 / 文件）+ 搜索。
/// V1.0.4：固定为列表展示（去掉布局切换键与 All 按钮），统计卡改为
/// 视频总数 / 占用空间 / 总时长，点击进入全部视频页。
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    /// Cut 被关掉就没有剪辑页，长按菜单不再给「剪辑」
    @AppStorage(TabPrefs.showCutKey) private var showCut = true
    private let config = AppConfig.current

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
                // V1.0.4：搜索时隐藏统计卡，只留结果列表。
                if searchText.isEmpty {
                    statsBar
                }

                if searchText.isEmpty {
                    folderSection
                    rootVideoSection
                } else {
                    searchResultsSection
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationDestination(
            isPresented: Binding(
                get: { debugFolder != nil },
                set: { if !$0 { debugFolder = nil } }
            )
        ) {
            if let folder = debugFolder {
                FolderDetailView(folder: folder)
                    .environmentObject(library)
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索视频名称")
        .toolbar {
            // V1.0.3：顶部只保留「+」，并且移到右上角，只负责新建文件夹。
            // 两个按钮当成一组整体左移：系统给 trailing 的默认 16pt 内边距偏右，
            // 用 offset 把整组往左推，间距不受 toolbar 布局影响。
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        textEdit = TextEditRequest(kind: .newFolder, parentID: nil)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    // 「＋」圆形图标的实际像素中心比相册图标低 ~2px，上移 0.5pt 让两者严格水平对齐。
                    .offset(y: -0.5)
                    .accessibilityLabel("在素材库根目录新建文件夹")

                    if config.allowsPhotoImport {
                        PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                            Image(systemName: "photo.badge.plus")
                        }
                        .accessibilityLabel("从相册导入")
                    }
                }
                .offset(x: -12)
            }
        }
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "openFirstFolder"), debugFolder == nil {
                debugFolder = library.rootFolders.first
            }
            if UserDefaults.standard.bool(forKey: "openEmptyFolder") {
                let emptyRoot = library.rootFolders.first {
                    library.videos(in: $0.id).isEmpty && library.subfolders(in: $0.id).isEmpty
                }
                debugFolder = emptyRoot ?? library.rootFolders.first.flatMap {
                    library.subfolders(in: $0.id).first {
                        library.videos(in: $0.id).isEmpty && library.subfolders(in: $0.id).isEmpty
                    }
                }
            }
            if let keyword = UserDefaults.standard.string(forKey: "searchKeyword"), searchText.isEmpty {
                searchText = keyword
            }
            if UserDefaults.standard.bool(forKey: "openFirstVideo"),
               case .none = route,
               let first = library.videos.first {
                route = .player(first)
            }
            if UserDefaults.standard.bool(forKey: "openEditorFirst"),
               case .none = route,
               let first = library.videos.first {
                route = .editor(.library(first))
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

    /// V1.0.4：视频总数 / 占用空间 / 总时长；整块可点，进入「全部视频」列表。
    private var statsBar: some View {
        NavigationLink {
            AllVideosView()
                .environmentObject(library)
        } label: {
            HStack(spacing: 0) {
                StatItem(value: "\(library.videos.count)", title: "视频")
                Divider().frame(height: 26)
                StatItem(value: library.totalSize.fileSizeText, title: "占用空间")
                Divider().frame(height: 26)
                StatItem(value: library.totalDuration.listTimecode, title: "总时长")
            }
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看全部视频")
    }

    // MARK: - 文件夹

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                // V1.0.5：副标题改成文件夹数量，不再写说明文案。
                SectionHeader(
                    title: "文件夹",
                    subtitle: "\(library.rootFolders.count) 个文件夹"
                )
                Spacer()
            }
            .padding(.top, 4)

            folderList
        }
    }

    /// V2.0.1：文件夹的列表形式（默认）。V2.0.2：移除顶部的新建文件夹 Cell。
    private var folderList: some View {
        VStack(spacing: 8) {
            if library.rootFolders.isEmpty {
                // V3.4：根目录一个文件夹都没有时给个引导，指向上右角的新建按钮
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "还没有文件夹",
                    message: "点击右上角，新建文件夹就会出现在这里。"
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            }

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

    // MARK: - 根目录视频（V1.0.3）

    private var rootVideos: [VideoItem] { library.videos(in: nil) }

    /// 根目录下的视频：与文件夹同一套 cell 样式，单行展示。
    private var rootVideoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: "视频",
                    subtitle: rootVideos.isEmpty
                        ? "导入的视频可再移动进文件夹"
                        : "\(rootVideos.count) 个 · \(rootVideos.reduce(Int64(0)) { $0 + $1.fileSize }.fileSizeText)"
                )
                Spacer()
            }

            if rootVideos.isEmpty {
                EmptyStateView(
                    symbol: "film",
                    title: "根目录还没有视频",
                    message: "点右上角相册图标导入，视频就会出现在这里。"
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rootVideos) { item in
                        Button {
                            route = .player(item)
                        } label: {
                            VideoListRow(item: item)
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
        }
    }

    @ViewBuilder
    private func videoContextMenu(for item: VideoItem) -> some View {
        Button {
            route = .player(item)
        } label: {
            Label("播放", systemImage: "play.fill")
        }
        if showCut {
            Button {
                route = .editor(.library(item))
            } label: {
                Label("剪辑", systemImage: "scissors")
            }
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

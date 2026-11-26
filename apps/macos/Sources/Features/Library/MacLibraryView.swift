import AppKit
import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// macOS 素材库：文件夹 + 视频网格，右键管理，双击进入文件夹。
struct MacLibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var openFolderID: UUID?
    @State private var searchText = ""

    @State private var playingVideo: VideoItem?
    @State private var renameVideoTarget: VideoItem?
    @State private var renameFolderTarget: VideoFolder?
    @State private var moveVideoTarget: VideoItem?
    @State private var showNewFolder = false

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var toast: String?

    private var currentFolder: VideoFolder? { library.folder(with: openFolderID) }

    private var displayedVideos: [VideoItem] {
        let base = library.videos(in: openFolderID)
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        decorated
            .sheet(item: $playingVideo) { item in
                MacPlayerView(item: item)
            }
            .sheet(item: $renameVideoTarget) { item in
                MacRenameSheet(title: "重命名视频", currentName: item.title) { newName in
                    library.renameVideo(item.id, to: newName)
                }
            }
            .sheet(item: $renameFolderTarget) { folder in
                MacRenameSheet(title: "重命名文件夹", currentName: folder.name) { newName in
                    library.renameFolder(folder.id, to: newName)
                }
            }
            .sheet(item: $moveVideoTarget) { item in
                MacMoveSheet(folders: library.folders, currentFolderID: item.folderID) { folderID in
                    library.moveVideo(item.id, to: folderID)
                }
            }
            .sheet(isPresented: $showNewFolder) {
                MacNewFolderSheet { name in
                    library.createFolder(named: name)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.8), in: Capsule())
                        .padding(.bottom, 20)
                }
            }
    }

    /// 页面主体 + 工具栏 / 搜索 / 导入事件（拆出来单纯是为了让类型推断能过）
    private var decorated: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .videos) {
                        Label("从相册导入", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        if let url = MacAlerts.chooseVideoFile() {
                            Task { await importFile(url) }
                        }
                    } label: {
                        Label("导入视频", systemImage: "plus")
                    }
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索视频标题")
            .onChange(of: photoPickerItem) { newValue in
                guard let newValue else { return }
                Task { await importPhoto(newValue) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macImportVideo)) { _ in
                if let url = MacAlerts.chooseVideoFile() {
                    Task { await importFile(url) }
                }
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if openFolderID == nil {
                    folderSection
                }

                videoSection
            }
            .padding(MacTheme.pagePadding)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            if openFolderID != nil {
                Button {
                    openFolderID = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("返回素材库")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(currentFolder?.name ?? "素材库")
                    .font(.title2.weight(.semibold))
                Text("\(displayedVideos.count) 个视频 · \(library.folders.count) 个文件夹 · \(library.totalSize.fileSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 文件夹

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹").font(.headline)
                Spacer()
                Button("新建") { showNewFolder = true }
                    .buttonStyle(.link)
            }

            if library.folders.isEmpty {
                Button {
                    showNewFolder = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").foregroundStyle(MacTheme.accent)
                        Text("新建第一个文件夹，把视频分类管理")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(library.folders) { folder in
                        MacFolderCard(
                            folder: folder,
                            videoCount: library.videoCount(in: folder.id),
                            coverThumbnails: library.coverThumbnails(for: folder.id),
                            onOpen: { openFolderID = folder.id }
                        )
                        .contextMenu {
                            Button("打开") { openFolderID = folder.id }
                            Button("重命名") { renameFolderTarget = folder }
                            Divider()
                            Button("删除（视频保留）") {
                                library.deleteFolder(folder.id, deleteVideos: false)
                            }
                            Button("删除（连同视频）", role: .destructive) {
                                guard MacAlerts.confirmDelete(
                                    title: "删除文件夹「\(folder.name)」？",
                                    message: "该文件夹内的 \(library.videoCount(in: folder.id)) 个视频会被一并删除，且不可恢复。"
                                ) else { return }
                                library.deleteFolder(folder.id, deleteVideos: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 视频

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(openFolderID == nil ? "全部视频" : "文件夹内视频").font(.headline)
                Spacer()
                if !displayedVideos.isEmpty {
                    Text("\(displayedVideos.count) 个").font(.caption).foregroundStyle(.secondary)
                }
            }

            if displayedVideos.isEmpty {
                MacEmptyStateView(
                    symbol: "film.stack",
                    title: openFolderID == nil ? "还没有视频" : "这个文件夹还是空的",
                    message: "支持从本地文件、系统相册导入；导入后即可播放、剪辑、分文件夹管理。",
                    actionTitle: "从文件导入",
                    action: {
                        if let url = MacAlerts.chooseVideoFile() {
                            Task { await importFile(url) }
                        }
                    }
                )
                .frame(height: 320)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 18) {
                    ForEach(displayedVideos) { item in
                        MacVideoCard(
                            item: item,
                            onPlay: { playingVideo = item },
                            onEdit: {
                                MacEditorWindowManager.shared.open(
                                    source: MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id),
                                    library: library
                                )
                            }
                        ) {
                            Button(item.isFavorite ? "取消收藏" : "收藏") {
                                library.toggleFavorite(item.id)
                            }
                            Button("重命名") { renameVideoTarget = item }
                            Button("移动到文件夹…") { moveVideoTarget = item }
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                guard MacAlerts.confirmDelete(
                                    title: "删除「\(item.title)」？",
                                    message: "视频文件会从素材库中移除，且不可恢复。"
                                ) else { return }
                                library.deleteVideo(item.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 导入

    private func importFile(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let temp = try VideoImporter.prepare(from: url)
            try await importTemp(temp, source: .files, suggestedTitle: url.deletingPathExtension().lastPathComponent)
        } catch {
            library.lastErrorMessage = error.localizedDescription
            toast = error.localizedDescription
        }
    }

    private func importPhoto(_ pickerItem: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let temp = try await VideoImporter.prepare(from: pickerItem)
            try await importTemp(temp, source: .photos, suggestedTitle: nil)
        } catch {
            toast = error.localizedDescription
        }
        photoPickerItem = nil
    }

    private func importTemp(_ temp: URL, source: VideoSource, suggestedTitle: String?) async throws {
        let item = try await library.importVideo(
            fromTempURL: temp,
            source: source,
            folderID: openFolderID,
            suggestedTitle: suggestedTitle
        )
        VideoImporter.cleanTemporaryFile(at: temp)
        toast = "已导入「\(item.title)」"
    }
}

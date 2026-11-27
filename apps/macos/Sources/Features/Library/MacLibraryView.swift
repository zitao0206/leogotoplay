import AppKit
import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// macOS Library 页（原 List）：统计条 + 文件夹 + 视频网格，搜索/导入/新建文件夹/播放器齐备。
struct MacLibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var openFolderID: UUID?
    @State private var searchText = ""

    @State private var renameVideoTarget: VideoItem?
    @State private var renameFolderTarget: VideoFolder?
    @State private var moveVideoTarget: VideoItem?
    @State private var showNewFolder = false

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var toast: String?

    /// 视频区布局：宫格 / 列表（V3.1.15）
    @AppStorage("libraryVideoLayout") private var videoLayout = "grid"
    /// 长按视频弹出的操作面板
    @State private var actionVideo: VideoItem?
    @State private var showVideoActions = false
    /// 长按文件夹弹出的操作面板
    @State private var actionFolder: VideoFolder?
    @State private var showFolderActions = false
    /// 正在移动的文件夹
    @State private var moveFolderTarget: VideoFolder?
    /// 正在删除的文件夹（弹二选一确认）
    @State private var deleteFolderTarget: VideoFolder?

    private var currentFolder: VideoFolder? { library.folder(with: openFolderID) }

    private var displayedSize: String {
        displayedVideos.reduce(into: Int64(0)) { $0 += $1.fileSize }.fileSizeText
    }

    private var displayedVideos: [VideoItem] {
        let base = library.videos(in: openFolderID)
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        decorated
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
            .sheet(item: $moveFolderTarget) { folder in
                MacMoveSheet(
                    folders: library.folders.filter { $0.id != folder.id },
                    currentFolderID: folder.parentID,
                    rootTitle: "根目录",
                    title: "移动文件夹"
                ) { parentID in
                    library.moveFolder(folder.id, to: parentID)
                    showToast("已移动文件夹「\(folder.name)」")
                }
            }
            .sheet(item: $deleteFolderTarget) { folder in
                MacFolderDeleteSheet(
                    folder: folder,
                    videoCount: library.videoCount(in: folder.id)
                ) {
                    library.deleteFolder(folder.id, deleteVideos: true)
                    showToast("已删除文件夹「\(folder.name)」及其中的视频")
                } onKeepVideos: {
                    library.deleteFolder(folder.id, deleteVideos: false)
                    showToast("已删除文件夹「\(folder.name)」，视频已移到根目录")
                }
            }
            .sheet(isPresented: $showNewFolder) {
                MacNewFolderSheet { name in
                    // 在子文件夹里新建 → 建在当前文件夹下；首页新建 → 建在根目录
                    _ = library.createFolder(named: name, parentID: openFolderID)
                    showToast("已创建文件夹「\(name)」")
                }
            }
            .overlay { videoActionsPanel }
            .overlay { folderActionsPanel }
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
                    .buttonStyle(MacAccentToolbarButtonStyle())
                    Button {
                        if let url = MacAlerts.chooseVideoFile() {
                            Task { await importFile(url) }
                        }
                    } label: {
                        Label("导入视频", systemImage: "plus")
                    }
                    .buttonStyle(MacAccentToolbarButtonStyle())
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(MacAccentToolbarButtonStyle())
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
                    statsBar
                    folderSection
                } else if !(library.subfolders(in: openFolderID).isEmpty) {
                    subfolderSection
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
                Text(currentFolder?.name ?? "Library")
                    .font(.title2.weight(.semibold))
                // 文件位置只在首页（未进入子文件夹）显示
                if openFolderID == nil {
                    HStack(spacing: 6) {
                        Text("文件位置：\(VideoFileStore.shared.mediaDirectory.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            copyStoragePath()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("复制文件夹路径")
                    }
                } else {
                    Text("\(displayedVideos.count) 个视频 · \(displayedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - 统计条（视频 / 占用空间 / 总时长，参考 iOS）

    private var statsBar: some View {
        HStack(spacing: 0) {
            statItem(value: "\(library.videos.count)", title: "视频")
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 26)
            statItem(value: library.totalSize.fileSizeText, title: "占用空间")
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 26)
            statItem(value: library.totalDuration.timecode, title: "总时长")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(MacTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func statItem(value: String, title: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 子文件夹（进入文件夹后展示它自己的下级文件夹）

    private var subfolderSection: some View {
        let children = library.subfolders(in: openFolderID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("文件夹").font(.system(size: 17, weight: .semibold))
                Text("\(children.count) 个文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("新建") { showNewFolder = true }
                    .buttonStyle(.link)
            }

            if children.isEmpty {
                Button {
                    showNewFolder = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").foregroundStyle(MacTheme.accent)
                        Text("在当前文件夹下新建一个子文件夹")
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
                VStack(spacing: 8) {
                    ForEach(children) { folder in
                        MacFolderRow(
                            folder: folder,
                            videoCount: library.videoCount(in: folder.id),
                            subfolderCount: library.subfolderCount(in: folder.id),
                            onOpen: { openFolderID = folder.id },
                            onLongPress: { showFolderActionsPanel(for: folder) }
                        )
                        .contextMenu {
                            Button("打开") { openFolderID = folder.id }
                            Button("重命名") { renameFolderTarget = folder }
                            Divider()
                            Button("删除…") { deleteFolderTarget = folder }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 文件夹

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("文件夹").font(.system(size: 17, weight: .semibold))
                Text("\(library.subfolders(in: nil).count) 个文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("新建") { showNewFolder = true }
                    .buttonStyle(.link)
            }

            if library.subfolders(in: nil).isEmpty {
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
                // V3.0.0：按 iOS 的列表样式排（一条文件夹一行）
                VStack(spacing: 8) {
                    ForEach(library.subfolders(in: nil)) { folder in
                        MacFolderRow(
                            folder: folder,
                            videoCount: library.videoCount(in: folder.id),
                            subfolderCount: library.subfolderCount(in: folder.id),
                            onOpen: { openFolderID = folder.id },
                            onLongPress: { showFolderActionsPanel(for: folder) }
                        )
                        .contextMenu {
                            Button("打开") { openFolderID = folder.id }
                            Button("重命名") { renameFolderTarget = folder }
                            Divider()
                            Button("删除…") { deleteFolderTarget = folder }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 视频

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("视频")
                    .font(.system(size: 17, weight: .semibold))
                if !displayedVideos.isEmpty {
                    Text("\(displayedVideos.count) 个 · \(displayedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !displayedVideos.isEmpty {
                    Picker("布局", selection: $videoLayout) {
                        Image(systemName: "square.grid.2x2").tag("grid")
                        Image(systemName: "list.bullet").tag("list")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 88)
                    .help("切换宫格 / 列表")
                }
            }

            if displayedVideos.isEmpty {
                MacEmptyStateView(
                    symbol: "film.stack",
                    title: openFolderID == nil ? "还没有视频" : "这个文件夹还是空的",
                    message: "支持从本地文件、系统相册导入；导入后即可播放、剪辑、分文件夹管理。",
                    actionTitle: "从本地导入",
                    action: {
                        if let url = MacAlerts.chooseVideoFile() {
                            Task { await importFile(url) }
                        }
                    }
                )
                .frame(height: 320)
            } else if videoLayout == "list" {
                VStack(spacing: 8) {
                    ForEach(displayedVideos) { item in
                        MacVideoRow(
                            item: item,
                            onPlay: { play(item) },
                            onLongPress: { showActions(for: item) }
                        ) {
                            videoMenuActions(for: item)
                        }
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 168), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(displayedVideos) { item in
                        MacVideoCard(
                            item: item,
                            onPlay: { play(item) },
                            onLongPress: { showActions(for: item) }
                        ) {
                            videoMenuActions(for: item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 视频操作（长按弹框 / 右键菜单共用一套）

    private func play(_ item: VideoItem) {
        MacPlayerWindowManager.shared.open(item: item, library: library)
    }

    private func showFolderActionsPanel(for folder: VideoFolder) {
        actionFolder = folder
        showFolderActions = true
    }

    private func dismissFolderActions() {
        showFolderActions = false
    }

    /// 长按 / 右键文件夹弹出的三项操作面板
    @ViewBuilder
    private var folderActionsPanel: some View {
        if showFolderActions, let folder = actionFolder {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissFolderActions() }

                VStack(spacing: 0) {
                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    Divider().overlay(Color.white.opacity(0.08))

                    MacActionPanelRow(title: "重命名", systemImage: "pencil") {
                        dismissFolderActions()
                        renameFolderTarget = folder
                    }
                    MacActionPanelRow(title: "移动", systemImage: "folder") {
                        dismissFolderActions()
                        moveFolderTarget = folder
                    }
                    MacActionPanelRow(title: "删除", systemImage: "trash", isDestructive: true) {
                        dismissFolderActions()
                        deleteFolderTarget = folder
                    }
                }
                .frame(width: 268)
                .background(MacTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    private func showActions(for item: VideoItem) {
        actionVideo = item
        showVideoActions = true
    }

    private func dismissActions() {
        showVideoActions = false
    }

    private func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

    /// 复制素材库视频文件夹路径到剪贴板
    private func copyStoragePath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VideoFileStore.shared.mediaDirectory.path, forType: .string)
        showToast("路径已复制")
    }

    /// 长按 / 右键弹出的四项操作面板
    @ViewBuilder
    private var videoActionsPanel: some View {
        if showVideoActions, let item = actionVideo {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissActions() }

                VStack(spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    Divider().overlay(Color.white.opacity(0.08))

                    MacActionPanelRow(title: "播放", systemImage: "play.fill") {
                        dismissActions()
                        play(item)
                    }
                    MacActionPanelRow(title: "重命名", systemImage: "pencil") {
                        dismissActions()
                        renameVideoTarget = item
                    }
                    MacActionPanelRow(title: "移动到文件夹", systemImage: "folder") {
                        dismissActions()
                        moveVideoTarget = item
                    }
                    MacActionPanelRow(title: "删除", systemImage: "trash", isDestructive: true) {
                        dismissActions()
                        confirmDelete(item)
                    }
                }
                .frame(width: 268)
                .background(MacTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func videoMenuActions(for item: VideoItem) -> some View {
        Button("播放") { play(item) }
        Button("重命名") { renameVideoTarget = item }
        Button("删除", role: .destructive) { confirmDelete(item) }
        Button("移动到文件夹") { moveVideoTarget = item }
    }

    private func confirmDelete(_ item: VideoItem) {
        guard MacAlerts.confirmDelete(
            title: "删除「\(item.title)」？",
            message: "视频文件会从素材库中移除，且不可恢复。"
        ) else { return }
        library.deleteVideo(item.id)
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

/// 操作面板里的一行按钮（自带 hover 高亮）
private struct MacActionPanelRow: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? Color.red : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .contentShape(Rectangle())
            .background(Color.white.opacity(hovering ? 0.08 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 工具栏按钮：App 主题色描边 + 半透明填充，hover / 按下变亮
private struct MacAccentToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(MacTheme.accent.opacity(configuration.isPressed ? 0.32 : 0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(MacTheme.accent.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
    }
}

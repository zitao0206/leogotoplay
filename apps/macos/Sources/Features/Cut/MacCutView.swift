import AppKit
import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// macOS 剪辑台：选择视频来源 -> 进入剪辑窗口；下方是最近素材。
struct MacCutView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var editingSource: MacEditorSource?
    @State private var playingVideo: VideoItem?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showLibraryPicker = false
    @State private var isImporting = false
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                entryRow
                recentSection
            }
            .padding(MacTheme.pagePadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: photoPickerItem) { newValue in
            guard let newValue else { return }
            Task { await importPhoto(newValue) }
        }
        .sheet(item: $editingSource) { source in
            MacEditorView(source: source)
                .environmentObject(library)
        }
        .sheet(item: $playingVideo) { item in
            MacPlayerView(item: item)
        }
        .sheet(isPresented: $showLibraryPicker) {
            MacSourcePickerSheet { item in
                editingSource = MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id)
            }
            .environmentObject(library)
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
        .task { openFirstVideoIfNeeded() }
    }

    /// Debug 启动参数 `-autoOpenFirstVideo YES`：直接打开最近一个视频的剪辑窗口，方便截图与联调。
    private func openFirstVideoIfNeeded() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "autoOpenFirstVideo"),
              editingSource == nil,
              let item = library.recentVideos.first else { return }
        editingSource = MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id)
        #endif
    }

    // MARK: - 主视觉

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LEOGOTOPLAY CUT")
                .font(.caption.weight(.bold))
                .foregroundStyle(MacTheme.accentSecondary)
                .tracking(2)
            Text("桌面剪辑台")
                .font(.system(size: 30, weight: .bold))
            Text("选一段视频，裁好起止点，导出为 mp4，或直接存入素材库 / 照片。")
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    showLibraryPicker = true
                } label: {
                    Label("从素材库选", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    if let url = MacAlerts.chooseVideoFile() {
                        Task { await importFile(url) }
                    }
                } label: {
                    Label("从文件导入", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1B1C21), Color(hex: 0x2B2320)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "scissors")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(MacTheme.accent.opacity(0.3))
                .padding(28)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var entryRow: some View {
        HStack(spacing: 14) {
            PhotosPicker(selection: $photoPickerItem, matching: .videos) {
                entryCard(symbol: "photo.on.rectangle.angled",
                          title: "从相册选片",
                          subtitle: "选择系统「照片」中的视频")
            }
            .buttonStyle(.plain)

            Button {
                if let url = MacAlerts.chooseVideoFile() {
                    Task { await importFile(url) }
                }
            } label: {
                entryCard(symbol: "doc.badge.plus",
                          title: "从本地文件导入",
                          subtitle: "支持 mov / mp4 等常见格式")
            }
            .buttonStyle(.plain)

            Button {
                showLibraryPicker = true
            } label: {
                entryCard(symbol: "square.grid.2x2",
                          title: "从素材库选",
                          subtitle: "\(library.videos.count) 个已导入视频")
            }
            .buttonStyle(.plain)

            if isImporting {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func entryCard(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(MacTheme.accent)
                .frame(width: 34, height: 34)
                .background(MacTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - 最近素材

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近素材").font(.headline)
                Spacer()
                Text("\(library.videos.count) 个视频").font(.caption).foregroundStyle(.secondary)
            }

            if library.recentVideos.isEmpty {
                MacEmptyStateView(
                    symbol: "film.stack",
                    title: "还没有素材",
                    message: "从相册或本地文件导入后，这里会显示最近使用的视频。"
                )
                .frame(height: 260)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 16) {
                    ForEach(library.recentVideos) { item in
                        MacVideoCard(
                            item: item,
                            onPlay: { playingVideo = item },
                            onEdit: { editingSource = MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id) }
                        ) {
                            Button(item.isFavorite ? "取消收藏" : "收藏") { library.toggleFavorite(item.id) }
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
            let item = try await library.importVideo(
                fromTempURL: temp,
                source: .files,
                suggestedTitle: url.deletingPathExtension().lastPathComponent
            )
            VideoImporter.cleanTemporaryFile(at: temp)
            toast = "已导入「\(item.title)」"
            editingSource = MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id)
        } catch {
            toast = error.localizedDescription
        }
    }

    private func importPhoto(_ pickerItem: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let temp = try await VideoImporter.prepare(from: pickerItem)
            let item = try await library.importVideo(fromTempURL: temp, source: .photos)
            VideoImporter.cleanTemporaryFile(at: temp)
            toast = "已导入「\(item.title)」"
            editingSource = MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id)
        } catch {
            toast = error.localizedDescription
        }
        photoPickerItem = nil
    }
}

/// 从素材库挑一个视频去剪辑。
struct MacSourcePickerSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let onPick: (VideoItem) -> Void

    @State private var searchText = ""

    private var videos: [VideoItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return library.videos }
        return library.searchVideos(keyword: keyword)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择素材").font(.headline)
                TextField("搜索标题", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if videos.isEmpty {
                MacEmptyStateView(symbol: "film.stack", title: "素材库为空", message: "先去「素材库」导入视频。")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(videos) { item in
                            Button {
                                onPick(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    MacThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 6)
                                        .frame(width: 80, height: 50)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.callout)
                                        Text("\(item.duration.timecode) · \(item.fileSize.fileSizeText)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 520)
    }
}

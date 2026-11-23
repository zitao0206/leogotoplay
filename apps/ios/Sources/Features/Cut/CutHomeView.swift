import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// Cut 页：剪辑入口。可以从相册、文件或素材库选视频直接进入编辑器。
struct CutHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    private let config = AppConfig.current

    @State private var photoItem: PhotosPickerItem?
    @State private var editorSource: EditorViewModel.Source?
    @State private var pendingTempURL: URL?
    @State private var showLibraryPicker = false
    @State private var showFileImporter = false
    @State private var isPreparing = false
    @State private var toastMessage: String?
    @State private var fileImportPurpose: FileImportPurpose = .edit

    private enum FileImportPurpose { case edit, importToLibrary }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickActions
                recentSection
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Cut")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toastMessage)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { await preparePhoto(item) }
        }
        .sheet(isPresented: $showLibraryPicker) {
            LibraryPickerSheet { item in
                showLibraryPicker = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    editorSource = .library(item)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .fullScreenCover(item: $editorSource, onDismiss: {
            if let url = pendingTempURL {
                VideoImporter.cleanTemporaryFile(at: url)
                pendingTempURL = nil
            }
        }) { source in
            VideoEditorView(source: source)
                .environmentObject(library)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("热门工具")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }

            // V3.0：原本文案位置换成工具入口，全部待开发，点了只提示。
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                toolEntry(icon: "sparkles", title: "AI 画质增强")
                toolEntry(icon: "wand.and.stars", title: "一键去水印")
                toolEntry(icon: "wand.and.rays", title: "一键成片")
                toolEntry(icon: "text.bubble", title: "智能字幕")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Theme.darkGradient
                RadialGradient(
                    colors: [Theme.accent.opacity(0.35), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 220
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func toolEntry(icon: String, title: String) -> some View {
        Button {
            toastMessage = "\(title) · 开发中"
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 快捷动作

    @ViewBuilder
    private var quickActions: some View {
        // V3.0：只保留「从相册选片」一个入口，整块居中，图标和文字都居中。
        if config.allowsPhotoImport {
            PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.accent.opacity(0.32))
                        )
                    Text(isPreparing ? "读取中…" : "从相册选片")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)   // 与上方卡片两边对齐
                .padding(.vertical, 16)   // 高度再比上一版多 5pt
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.accentSoftGradient)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.14), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparing)
        }
    }

    // MARK: - 最近编辑

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近编辑")

            if library.recentVideos.isEmpty {
                EmptyStateView(
                    symbol: "film",
                    title: "还没有素材",
                    message: "先从相册导入一个视频，它就出现在这里。",
                    actionTitle: "从文件导入",
                    action: {
                        fileImportPurpose = .importToLibrary
                        showFileImporter = true
                    }
                )
                .cardBackground()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(library.recentVideos) { item in
                            Button {
                                editorSource = .library(item)
                            } label: {
                                VideoCard(item: item)
                                    .frame(width: 148)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 导入

    private func preparePhoto(_ item: PhotosPickerItem) async {
        isPreparing = true
        defer {
            isPreparing = false
            photoItem = nil
        }
        do {
            let url = try await VideoImporter.prepare(from: item)
            pendingTempURL = url
            editorSource = .temporary(url, title: "相册视频")
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let tempURL = try VideoImporter.prepare(from: url)
            let title = url.deletingPathExtension().lastPathComponent

            switch fileImportPurpose {
            case .edit:
                pendingTempURL = tempURL
                editorSource = .temporary(tempURL, title: title)
            case .importToLibrary:
                Task {
                    do {
                        try await library.importVideo(fromTempURL: tempURL, source: .files, suggestedTitle: title)
                        toastMessage = "已导入素材库"
                    } catch {
                        toastMessage = error.localizedDescription
                    }
                    VideoImporter.cleanTemporaryFile(at: tempURL)
                }
            }
        } catch {
            toastMessage = error.localizedDescription
        }
    }
}

// MARK: - 素材库选择器

private struct LibraryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let onSelect: (VideoItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if library.videos.isEmpty {
                    EmptyStateView(
                        symbol: "film",
                        title: "素材库是空的",
                        message: "先在 List 页导入视频，再回来剪辑。"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                            ForEach(library.videos) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    VideoCard(item: item, showsFolderName: true,
                                              folderName: library.folder(with: item.folderID)?.name)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(Theme.pagePadding)
                    }
                }
            }
            .navigationTitle("选择素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

extension EditorViewModel.Source: Identifiable {
    var id: String { url.path + "|" + title }
}

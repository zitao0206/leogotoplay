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
                workflowCard
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
                Text("LEOGOTOPLAY CUT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(1.6)
                Spacer()
                Image(systemName: "scissors")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text("把拍下的片段\n剪成一段作品")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .lineSpacing(2)

            Text("支持从相册或素材库选片，裁剪后可直接存回相册，也能收进 App 素材库。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if config.allowsPhotoImport {
                    PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                        Label(isPreparing ? "读取中…" : "从相册选片", systemImage: "photo.on.rectangle.angled")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .disabled(isPreparing)
                }

                Button {
                    showLibraryPicker = true
                } label: {
                    Label("从素材库选", systemImage: "square.stack.3d.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
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

    // MARK: - 快捷动作

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionTile(
                icon: "folder.badge.plus",
                title: "导入到素材库",
                subtitle: "从相册或文件添加视频"
            ) {
                fileImportPurpose = .importToLibrary
                showFileImporter = true
            }

            actionTile(
                icon: "film.stack",
                title: "素材管理",
                subtitle: "\(library.videos.count) 个视频 · \(library.folders.count) 个文件夹"
            ) {
                showLibraryPicker = true
            }
        }
    }

    private func actionTile(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近素材

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近素材", subtitle: "点一下就能继续剪")

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

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("剪辑流程")
                .font(.footnote.weight(.semibold))
            HStack(spacing: 8) {
                flowStep(index: 1, title: "选片")
                flowStep(index: 2, title: "裁剪")
                flowStep(index: 3, title: "导出 / 入库")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func flowStep(index: Int, title: String) -> some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.accent, in: Circle())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

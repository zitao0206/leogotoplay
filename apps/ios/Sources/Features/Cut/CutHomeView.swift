import AVFoundation
import PhotosUI
import SwiftUI
import LeogotoPlayCore

/// V3.5：用 sheet(item:) 承载提取页，避免 sheet 内容闭包拿到过期的 URL 状态
struct TextExtractRequest: Identifiable {
    let id = UUID()
    let url: URL?
}

/// Cut 页：剪辑入口。可以从相册或素材库选视频直接进入编辑器。
struct CutHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    private let config = AppConfig.current

    @State private var photoItem: PhotosPickerItem?
    @State private var editorSource: EditorViewModel.Source?
    @State private var pendingTempURL: URL?
    @State private var showLibraryPicker = false
    @State private var isPreparing = false
    @State private var toastMessage: String?
    /// V3.5：一键提取文字页面
    @State private var textExtractRequest: TextExtractRequest?
    /// V3.6：一键人脸打码页面
    @State private var faceMaskRequest: FaceMaskRequest?
    /// V3.7：一键视频增强页面
    @State private var enhanceRequest: VideoEnhanceRequest?
    /// V3.8：一键提取人脸页面
    @State private var faceExtractRequest: FaceExtractRequest?
    /// 丢弃草稿后让「最近编辑」重新读一遍草稿状态
    @State private var draftRevision = 0
    /// 最近编辑里待删除的视频
    @State private var pendingDeleteVideo: VideoItem?

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
        .confirmationDialog(
            pendingDeleteVideo.map { "删除「\($0.title)」？" } ?? "删除视频？",
            isPresented: Binding(
                get: { pendingDeleteVideo != nil },
                set: { if !$0 { pendingDeleteVideo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除视频", role: .destructive) {
                if let item = pendingDeleteVideo {
                    EditorDraftStore.clear(for: item)
                    library.deleteVideo(item.id)
                    draftRevision += 1
                    toastMessage = "视频已删除"
                }
                pendingDeleteVideo = nil
            }
            Button("取消", role: .cancel) { pendingDeleteVideo = nil }
        } message: {
            Text("会连同素材库里的文件、缩略图和草稿一起删掉，相册里的原片不受影响。")
        }
        #if DEBUG
        .onAppear {
            // 截图钩子：直接打开「一键提取文字」，并带一个素材库视频进去
            if UserDefaults.standard.bool(forKey: "openTextExtract") {
                let url = library.videos.first?.fileURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    textExtractRequest = TextExtractRequest(url: url)
                }
            } else if UserDefaults.standard.bool(forKey: "textExtractPageOnly") {
                textExtractRequest = TextExtractRequest(url: nil)
            }
            // 截图钩子：用测试视频（Documents/face-test.mp4）打开「一键人脸打码」
            if UserDefaults.standard.bool(forKey: "openFaceMaskTest") {
                let testURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("face-test.mp4")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    faceMaskRequest = FaceMaskRequest(url: testURL)
                }
            }
            // 截图钩子：直接弹「删除视频」确认框（取消即可，不会真删）
            if UserDefaults.standard.bool(forKey: "cutDeleteDialog") {
                pendingDeleteVideo = library.recentVideos.first
            }
            // 截图钩子：直接打开「一键人脸打码」
            if UserDefaults.standard.bool(forKey: "openFaceMask") {
                let url = library.videos.first?.fileURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    faceMaskRequest = FaceMaskRequest(url: url)
                }
            } else if UserDefaults.standard.bool(forKey: "faceMaskPageOnly") {
                faceMaskRequest = FaceMaskRequest(url: nil)
            }
            // 截图钩子：用测试视频（Documents/face-test.mp4）打开「一键视频增强」
            if UserDefaults.standard.bool(forKey: "openEnhanceTest") {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let shortURL = docs.appendingPathComponent("enhance-test.mp4")
                let testURL = FileManager.default.fileExists(atPath: shortURL.path)
                    ? shortURL
                    : docs.appendingPathComponent("face-test.mp4")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    enhanceRequest = VideoEnhanceRequest(url: testURL)
                }
            } else if UserDefaults.standard.bool(forKey: "enhancePageOnly") {
                enhanceRequest = VideoEnhanceRequest(url: nil)
            }
            // 截图钩子：用测试视频（Documents/face-test.mp4）打开「一键提取人脸」
            if UserDefaults.standard.bool(forKey: "openFaceExtractTest") {
                let testURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("face-test.mp4")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    faceExtractRequest = FaceExtractRequest(url: testURL)
                }
            } else if UserDefaults.standard.bool(forKey: "faceExtractPageOnly") {
                faceExtractRequest = FaceExtractRequest(url: nil)
            }
        }
        #endif
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
        .fullScreenCover(item: $textExtractRequest) { request in
            TextExtractView(debugURL: request.url)
        }
        .fullScreenCover(item: $faceMaskRequest) { request in
            FaceMaskView(debugURL: request.url)
                .environmentObject(library)
        }
        .fullScreenCover(item: $enhanceRequest) { request in
            VideoEnhanceView(debugURL: request.url)
                .environmentObject(library)
        }
        .fullScreenCover(item: $faceExtractRequest) { request in
            FaceExtractView(debugURL: request.url)
        }
        .fullScreenCover(item: $editorSource, onDismiss: {
            if let url = pendingTempURL {
                VideoImporter.cleanTemporaryFile(at: url)
                pendingTempURL = nil
            }
            // 剪辑页刚存完草稿，让「最近编辑」重新读一遍角标
            draftRevision += 1
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
                // V3.8：扫出视频里出现过的每张脸，裁成图片
                toolEntry(icon: "person.crop.rectangle", title: "一键提取人脸") {
                    faceExtractRequest = FaceExtractRequest(url: nil)
                }
                toolEntry(icon: "face.dashed", title: "一键人脸打码") {
                    faceMaskRequest = FaceMaskRequest(url: nil)
                }
                toolEntry(icon: "sparkles", title: "一键视频增强") {
                    enhanceRequest = VideoEnhanceRequest(url: nil)
                }
                toolEntry(icon: "text.viewfinder", title: "一键提取文字") {
                    textExtractRequest = TextExtractRequest(url: nil)
                }
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

    private func toolEntry(icon: String, title: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action {
                action()
            } else {
                toastMessage = "\(title) · 开发中"
            }
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
                // V3.4：这里不再给「从文件导入」按钮，导入入口统一留在上面的相册入口
                EmptyStateView(
                    symbol: "film",
                    title: "还没有视频",
                    message: "先从相册选一个视频剪一次，它就会出现在这里。"
                )
                .cardBackground()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(library.recentVideos) { item in
                            recentCard(item)
                        }
                    }
                    .padding(.vertical, 2)
                    .id(draftRevision)
                }
            }
        }
    }

    /// 最近编辑里的一张卡：一律按草稿处理，角标写草稿的成片时长（还没打开过的按原片时长）
    private func recentCard(_ item: VideoItem) -> some View {
        let draft = EditorDraftStore.draft(for: item)
        let badgeDuration = draft?.outputDuration ?? item.duration
        return Button {
            // 编辑器载入时会自动还原上次的现场；没打开过的从完整片段开始
            editorSource = .library(item)
        } label: {
            VideoCard(item: item)
                .frame(width: 148)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text("草稿")
                            .font(.caption2.weight(.bold))
                        Text(badgeDuration.timecode)
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                    .padding(6)
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editorSource = .library(item)
            } label: {
                Label("编辑", systemImage: "scissors")
            }
            Button(role: .destructive) {
                pendingDeleteVideo = item
            } label: {
                Label("删除", systemImage: "trash")
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

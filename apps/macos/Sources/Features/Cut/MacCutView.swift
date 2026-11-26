import AppKit
import SwiftUI
import LeogotoPlayCore

/// macOS 剪辑台（V2.0）：深色淡红底，首页三段式 —— 热门工具 / 添加并开始编辑 / 最近编辑。
struct MacCutView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var playingVideo: VideoItem?
    @State private var toast: String?
    /// 删掉草稿后让「最近编辑」重新读一遍草稿状态
    @State private var draftRevision = 0

    /// 热门工具：macOS 端先把入口摆齐，能力后续逐个接（点只提示）。
    private let tools: [(icon: String, title: String)] = [
        ("person.crop.rectangle", "一键提取人脸"),
        ("face.dashed", "一键人脸打码"),
        ("sparkles", "一键视频增强"),
        ("text.viewfinder", "一键提取文字")
    ]

    var body: some View {
        // V2.3：进剪辑一律新开一个独立窗口，本页始终停在首页
        home
            .onReceive(NotificationCenter.default.publisher(for: .macEditorWindowClosed)) { _ in
                draftRevision += 1
            }
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 18) {
                hotTools
                startEditCard
                recentSection
            }
            .padding(.horizontal, MacTheme.pagePadding)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(MacTheme.canvas)
        .sheet(item: $playingVideo) { item in
            MacPlayerView(item: item)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.82), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.bottom, 22)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast)
        .task {
            openFirstVideoIfNeeded()
        }
    }

    /// Debug 启动参数 `-autoOpenFirstVideo YES`：直接打开最近一个视频的剪辑窗口，方便截图与联调。
    private func openFirstVideoIfNeeded() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "autoOpenFirstVideo") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let item = library.recentVideos.first else { return }
            MacEditorWindowManager.shared.open(
                source: MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id),
                library: library
            )
        }
        #endif
    }

    // MARK: - 热门工具

    private var hotTools: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("热门工具")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(MacTheme.accent.opacity(0.92))
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: tools.count),
                spacing: 10
            ) {
                ForEach(tools, id: \.title) { tool in
                    MacToolTile(icon: tool.icon, title: tool.title) {
                        toast = "\(tool.title) · macOS 端开发中"
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(MacTheme.inkGradient)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [MacTheme.accent.opacity(0.30), .clear],
                            center: .topTrailing,
                            startRadius: 4,
                            endRadius: 320
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(MacTheme.inkStroke, lineWidth: 1)
        )
    }

    // MARK: - 添加 + 开始编辑

    private var startEditCard: some View {
        Button {
            // 新开一个剪辑窗口（先空着，视频从窗口里的素材墙拖进编辑区载入）
            MacEditorWindowManager.shared.open(source: nil, library: library)
        } label: {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MacTheme.accent.opacity(0.18))
                    )
                Text("开始编辑")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 27)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(MacTheme.surface)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MacTheme.accent.opacity(0.13), MacTheme.accent.opacity(0.03)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MacTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - 最近编辑

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近编辑")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(library.recentVideos.count) 个视频")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            if library.recentVideos.isEmpty {
                MacEmptyStateView(
                    symbol: "film",
                    title: "还没有视频",
                    message: "点上面的「开始编辑」选一个本地视频，剪完就会留在这里。"
                )
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(MacTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(MacTheme.inkStroke, lineWidth: 1)
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(library.recentVideos) { item in
                            MacRecentEditCard(
                                item: item,
                                draft: MacEditorDraftStore.draft(for: item.id),
                                onOpen: {
                                    MacEditorWindowManager.shared.open(
                                        source: MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id),
                                        library: library
                                    )
                                },
                                onDelete: { delete(item) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                    .id(draftRevision)
                }
            }
        }
    }

    // MARK: - 动作

    private func delete(_ item: VideoItem) {
        guard MacAlerts.confirmDelete(
            title: "删除「\(item.title)」？",
            message: "会连同素材库里的文件、缩略图和草稿一起删掉。"
        ) else { return }
        MacEditorDraftStore.clear(for: item.id)
        library.deleteVideo(item.id)
        draftRevision += 1
        toast = "视频已删除"
    }
}

// MARK: - 热门工具格子

private struct MacToolTile: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(hovering ? 0.12 : 0.04), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 最近编辑卡片

private struct MacRecentEditCard: View {
    let item: VideoItem
    let draft: MacEditorDraft?
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private var badgeDuration: Double { draft?.outputDuration ?? item.duration }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    MacThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 10)
                        .frame(width: 200, height: 112)
                        .clipped()

                    Text(badgeDuration.timecode)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if draft != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 9, weight: .bold))
                            Text("草稿")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(MacTheme.accent, in: Capsule())
                        .padding(6)
                    }
                }

                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 200, alignment: .leading)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MacTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(hovering ? 0.18 : 0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(draft == nil ? "打开剪辑台" : "继续上次的裁剪")
        .contextMenu {
            Button("继续编辑", action: onOpen)
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private var subtitle: String {
        guard let draft else {
            return "未编辑 · \(item.fileSize.fileSizeText)"
        }
        return "草稿 · \(Self.relativeFormatter.localizedString(for: draft.updatedAt, relativeTo: Date()))"
    }
}

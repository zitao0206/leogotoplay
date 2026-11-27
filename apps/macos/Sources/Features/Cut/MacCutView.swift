import AppKit
import SwiftUI
import LeogotoPlayCore

/// macOS 剪辑台（V2.0）：深色淡红底，首页三段式 —— 热门工具 / 添加并开始编辑 / 最近编辑。
struct MacCutView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var playingVideo: VideoItem?
    @State private var toast: String?
    /// 最近编辑的项目（V2.8.6：来自项目存档，每条都是动过时间轴的现场）
    @State private var projects: [MacProjectRecord] = []
    /// 正在改名的项目（V2.9.5：格子右下角「…」里的重命名）
    @State private var renamingProject: MacProjectRecord?
    @State private var renameDraft = ""

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
                reloadProjects()
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
        .alert("重命名项目", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("项目名称", text: $renameDraft)
            Button("取消", role: .cancel) { renamingProject = nil }
            Button("确定") {
                if let project = renamingProject, !renameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    MacProjectStore.rename(project.id, to: renameDraft)
                    reloadProjects()
                    toast = "已重命名"
                }
                renamingProject = nil
            }
        }
        .task {
            reloadProjects()
            openFirstVideoIfNeeded()
        }
    }

    /// Debug 启动参数 `-autoOpenFirstVideo YES`：直接打开最近一个视频的剪辑窗口，方便截图与联调。
    private func openFirstVideoIfNeeded() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "autoOpenFirstVideo") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let project = MacProjectStore.recentProjects().first {
                MacEditorWindowManager.shared.open(projectID: project.id, library: library)
            } else if let item = library.recentVideos.first {
                MacEditorWindowManager.shared.open(
                    source: MacEditorSource(url: item.fileURL, title: item.title, libraryVideoID: item.id),
                    library: library
                )
            }
        }
        #endif
    }

    private func reloadProjects() {
        projects = MacProjectStore.recentProjects()
    }

    private func beginRename(_ project: MacProjectRecord) {
        renameDraft = project.title
        renamingProject = project
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
                Text("\(projects.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            if projects.isEmpty {
                MacEmptyStateView(
                    symbol: "film",
                    title: "还没有编辑过的项目",
                    message: "点上面的「开始编辑」，把素材拖进时间轴，剪完就会留在这里。"
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
                // V2.9.5：宫格自适应 —— 窗口变宽多排一列，变窄自动回收，纵向滚动到底
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 208, maximum: 320), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(projects) { project in
                        MacRecentProjectCard(
                            project: project,
                            onOpen: {
                                MacEditorWindowManager.shared.open(projectID: project.id, library: library)
                            },
                            onDelete: { delete(project) },
                            onRename: { beginRename(project) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 动作

    private func delete(_ project: MacProjectRecord) {
        guard MacAlerts.confirmDelete(
            title: "删除「\(project.title)」？",
            message: "会连同项目里导入的素材文件、缩略图和整条时间轴现场一起删掉。"
        ) else { return }
        MacProjectStore.remove(project.id)
        reloadProjects()
        toast = "项目已删除"
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

// MARK: - 最近编辑卡片（V2.8.6：一个项目一张卡，缩略图取首条素材的首帧）

private struct MacRecentProjectCard: View {
    let project: MacProjectRecord
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    @State private var hovering = false
    /// 右下角「…」的小菜单
    @State private var showMenu = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        // V3.0.0：每个格子固定正方形（缩略图铺满，标题压在底部渐变上）
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MacTheme.surface)

            cover
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipped()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.trailing, 22)
                    Text("现场 · \(Self.relativeFormatter.localizedString(for: project.updatedAt, relativeTo: Date()))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .padding(.trailing, 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .padding(.top, 26)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.15), .black.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            HStack(spacing: 3) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 9, weight: .bold))
                Text("\(project.clips.count) 段")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(MacTheme.accent, in: Capsule())
            .padding(8)

            Text(project.outputDuration.timecode)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.18 : 0.06), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Button {
                showMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                    .frame(width: 20, height: 18)
                    .background(Color.white.opacity(hovering ? 0.18 : 0.08),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 18)
            .padding(8)
            .help("重命名 / 删除")
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        showMenu = false
                        onRename()
                    } label: {
                        Label("重命名", systemImage: "pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)

                    Button {
                        showMenu = false
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .font(.system(size: 12))
                .padding(6)
                .frame(width: 120)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help("继续上次的时间轴现场")
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let id = project.coverMaterialID,
               let image = MacProjectStore.thumbnail(for: id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
    }
}

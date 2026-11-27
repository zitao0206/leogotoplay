import SwiftUI
import LeogotoPlayCore

/// Mine 页：账号卡片、素材统计、设置入口、退出登录。
struct MineView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthStore

    @State private var showLogin = false
    @State private var showSettings = false
    @State private var showTabLayout = false

    // 和 TabLayoutView / RootTabView 共用同一组 key，用来实时刷新「首页 TAB」那行的副标题
    @AppStorage(TabPrefs.showListKey) private var showList = true
    @AppStorage(TabPrefs.showCutKey) private var showCut = true
    @State private var showAbout = false
    @State private var showLogoutConfirm = false
    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                profileCard
                statsCard
                actionList
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Mine")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toastMessage)
        .sheet(isPresented: $showLogin) {
            LoginView()
                .environmentObject(auth)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showTabLayout) {
            TabLayoutView()
        }
        .alert("关于 LeogotoPlay", isPresented: $showAbout) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("LeogotoPlay 0.1.0\n视频管理 · 基础剪辑 · 播放器\n当前为本地基础架构版本，账号与数据均保存在本机。")
        }
        .confirmationDialog("退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                auth.logout()
                toastMessage = "已退出登录"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后视频库仍保留在本机，重新登录可继续使用。")
        }
    }

    // MARK: - 账号卡片

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.18))
                        .frame(width: 56, height: 56)
                    if let user = auth.session?.user {
                        Text(user.initial)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(auth.session?.user.nickname ?? "未登录")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(auth.session?.user.email ?? "登录后可同步账号信息")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer()
            }

            if auth.isLoggedIn {
                HStack(spacing: 8) {
                    Label("本机账号已登录", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    if let issuedAt = auth.session?.issuedAt {
                        Text("登录于 \(issuedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Text("登录 / 注册")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.2), in: Capsule())
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Theme.darkGradient
                RadialGradient(
                    colors: [Theme.accent.opacity(0.4), .clear],
                    center: .topTrailing,
                    startRadius: 2,
                    endRadius: 240
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - 统计

    private var statsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                StatItem(value: "\(library.videos.count)", title: "视频")
                Divider().frame(height: 26)
                StatItem(value: "\(library.folders.count)", title: "文件夹")
                Divider().frame(height: 26)
                StatItem(value: library.totalSize.fileSizeText, title: "占用空间")
            }
            Divider()
            HStack {
                Label("总时长", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(library.totalDuration.timecode)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 操作列表

    private var actionList: some View {
        VStack(spacing: 0) {
            // V4.0：功能选择（List / Cut 显隐），放在最上面
            actionRow(icon: "rectangle.split.3x1", title: "功能选择", subtitle: tabLayoutSubtitle) {
                showTabLayout = true
            }
            Divider().padding(.leading, 48)

            actionRow(icon: "slider.horizontal.3", title: "导出与播放设置", subtitle: "清晰度、循环播放") {
                showSettings = true
            }
            Divider().padding(.leading, 48)

            actionRow(icon: "photo.stack", title: "清理缩略图缓存", subtitle: "不会删除任何视频") {
                library.clearThumbnailCache()
                ImageCache.clear()
                toastMessage = "缩略图缓存已清理"
            }
            Divider().padding(.leading, 48)

            actionRow(icon: "info.circle", title: "关于 LeogotoPlay", subtitle: "版本 0.1.0") {
                showAbout = true
            }

            if auth.isLoggedIn {
                Divider().padding(.leading, 48)
                actionRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录", subtitle: nil, destructive: true) {
                    showLogoutConfirm = true
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    /// Mine 列表里「首页 TAB」那一行的副标题，直接反映当前选择
    private var tabLayoutSubtitle: String {
        switch (showList, showCut) {
        case (true, true): return "List + Cut"
        case (true, false): return "Library"
        case (false, true): return "Cut"
        default: return "List + Cut"
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String?,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(destructive ? Color.red : Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

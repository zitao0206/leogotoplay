import AppKit
import SwiftUI
import LeogotoPlayCore

/// macOS「我的」：账号（登录/注册/退出）+ 库统计 + 设置。
struct MacMineView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nickname = ""

    // V4.0：功能选择（Library / Cut 至少留一个），侧栏按这里实时过滤
    @AppStorage(MacTabPrefs.showListKey) private var showLibrary = true
    @AppStorage(MacTabPrefs.showCutKey) private var showCut = true

    /// 本地缓存（缩略图目录）当前占用，进来后每 2 秒刷新一次
    @State private var cacheBytes: Int64 = 0

    private enum Mode: String, CaseIterable { case login, register }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountCard
                statsCard
                featureCard
                settingsCard
            }
            .padding(MacTheme.pagePadding)
        }
        .background(MacTheme.canvas)
        .navigationTitle("我的")
        .task {
            // 「实时」显示缓存大小：浏览视频会不断生成缩略图，所以边看边刷
            while !Task.isCancelled {
                cacheBytes = Self.thumbnailCacheSize()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session = auth.session {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(MacTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.user.nickname).font(.title3.weight(.semibold))
                        Text(session.user.email).font(.caption).foregroundStyle(.secondary)
                        Text("登录时间 \(session.issuedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("退出登录") { auth.logout() }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("登录后同步你的账号状态").font(.headline)
                Picker("", selection: $mode) {
                    Text("登录").tag(Mode.login)
                    Text("注册").tag(Mode.register)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                if mode == .register {
                    TextField("昵称（可留空）", text: $nickname)
                        .textFieldStyle(.roundedBorder)
                }
                TextField("邮箱", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360, alignment: .leading)
                SecureField("密码（至少 6 位）", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360, alignment: .leading)

                if let message = auth.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            if mode == .login {
                                await auth.login(email: email, password: password)
                            } else {
                                await auth.register(nickname: nickname, email: email, password: password)
                            }
                        }
                    } label: {
                        if auth.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(mode == .login ? "登录" : "注册并登录")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(email.isEmpty || password.isEmpty || auth.isBusy)
                }

                Text("当前为本地账号实现（密码加盐哈希 + Keychain 保存登录态），接入后端只需替换 AuthServicing 实现。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 统计

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频库").font(.headline)
            HStack(spacing: 0) {
                stat(value: "\(library.videos.count)", title: "视频")
                Divider().frame(height: 34)
                stat(value: "\(library.folders.count)", title: "文件夹")
                Divider().frame(height: 34)
                stat(value: library.totalSize.fileSizeText, title: "占用空间")
                Divider().frame(height: 34)
                stat(value: library.totalDuration.timecode, title: "总时长")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func stat(value: String, title: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 设置

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置").font(.headline).padding(.bottom, 10)

            settingRow("本地缓存") {
                HStack(spacing: 10) {
                    Text(cacheBytes.fileSizeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("清理缓存") {
                        library.clearThumbnailCache()
                        MacImageCache.clear()
                        cacheBytes = Self.thumbnailCacheSize()
                    }
                    .buttonStyle(.link)
                }
            }

            Divider()

            settingRow("关于 LeogotoPlay") {
                Text("v0.1.0 · macOS 基础架构")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    /// V4.0：功能选择——Library / Cut 至少留一个（仿 iOS 的 TabLayoutView）
    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("功能选择").font(.headline).padding(.bottom, 4)
            Text("至少保留一个功能；关掉的那个不会出现在左侧栏。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            settingRow("Library · 视频库") {
                Toggle("", isOn: $showLibrary)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    // Cut 已经关了就不能再关 Library（否则侧栏空掉）
                    .disabled(!showCut)
            }

            Divider()

            settingRow("Cut · 剪辑台") {
                Toggle("", isOn: $showCut)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!showLibrary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    /// 缩略图目录的磁盘占用（缓存「有多大」就是它 + 少量内存缓存）
    private static func thumbnailCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(
            at: VideoFileStore.shared.thumbnailDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            content()
        }
        .padding(.vertical, 10)
    }
}

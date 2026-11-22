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

    @AppStorage(ExportSettings.qualityKey) private var qualityRaw = VideoExporter.Quality.p1080.rawValue
    @AppStorage(ExportSettings.autoLoopKey) private var autoLoop = false
    @AppStorage(ExportSettings.autoSaveToAlbumKey) private var autoSaveToAlbum = true

    private enum Mode: String, CaseIterable { case login, register }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountCard
                statsCard
                settingsCard
            }
            .padding(MacTheme.pagePadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("我的")
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
            Text("素材库").font(.headline)
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

            settingRow("默认导出清晰度") {
                Picker("", selection: $qualityRaw) {
                    ForEach(VideoExporter.Quality.allCases) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Divider()

            settingRow("播放时循环") {
                Toggle("", isOn: $autoLoop).labelsHidden().toggleStyle(.switch)
            }

            Divider()

            settingRow("iOS 端剪辑后自动存入相册") {
                Toggle("", isOn: $autoSaveToAlbum).labelsHidden().toggleStyle(.switch)
            }

            Divider()

            settingRow("本地文件位置") {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([VideoFileStore.shared.root])
                }
                .buttonStyle(.link)
            }

            Divider()

            settingRow("缩略图缓存") {
                Button("清理缩略图缓存") {
                    library.clearThumbnailCache()
                    MacImageCache.clear()
                }
                .buttonStyle(.link)
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

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            content()
        }
        .padding(.vertical, 10)
    }
}

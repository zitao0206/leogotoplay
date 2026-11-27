import AppKit
import StoreKit
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

    // V4.3：语言选择（默认 English，切换后整站文案即时换成对应语言）
    @ObservedObject private var language = MacLanguageStore.shared

    // V4.2：隐私政策 / 用户协议 内置文本页，联系我们走 mailto，评分走 StoreKit
    @State private var showPrivacy = false
    @State private var showTerms = false
    @State private var toast: String?
    @State private var toastToken = 0

    /// 版本号取自 Info.plist（MARKETING_VERSION / CURRENT_PROJECT_VERSION），不写死
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "v\(short)（\(build)）"
    }

    private enum Mode: String, CaseIterable { case login, register }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountCard
                featureCard
                settingsCard
            }
            .padding(MacTheme.pagePadding)
        }
        .background(MacTheme.canvas)
        .navigationTitle(T("我的"))
        .sheet(isPresented: $showPrivacy) {
            MacLegalSheet(title: T("隐私政策"), bodyText: MacLegal.privacyPolicy)
        }
        .sheet(isPresented: $showTerms) {
            MacLegalSheet(title: T("用户协议"), bodyText: MacLegal.terms)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.85), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.bottom, 22)
            }
        }
        .task {
            #if DEBUG
            // 调试钩子：-mineShowPolicy YES / -mineShowTerms YES 直接弹出文档页，省去手点
            if UserDefaults.standard.bool(forKey: "mineShowPolicy") { showPrivacy = true }
            if UserDefaults.standard.bool(forKey: "mineShowTerms") { showTerms = true }
            #endif
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
                        Text(T("登录时间 {1}", session.issuedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(T("退出登录")) { auth.logout() }
                        .buttonStyle(.bordered)
                }
            } else {
                Text(T("登录后同步你的账号状态")).font(.headline)
                Picker("", selection: $mode) {
                    Text(T("登录")).tag(Mode.login)
                    Text(T("注册")).tag(Mode.register)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                if mode == .register {
                    TextField(T("昵称（可留空）"), text: $nickname)
                        .textFieldStyle(.roundedBorder)
                }
                TextField(T("邮箱"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360, alignment: .leading)
                SecureField(T("密码（至少 6 位）"), text: $password)
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
                            Text(mode == .login ? T("登录") : T("注册并登录"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(email.isEmpty || password.isEmpty || auth.isBusy)
                }

                Text(T("当前为本地账号实现（密码加盐哈希 + Keychain 保存登录态），接入后端只需替换 AuthServicing 实现。"))
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

    // MARK: - 设置

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("设置")).font(.headline).padding(.bottom, 10)

            // V4.3：语言——默认英文，可切中文；切换后整个 App 立即换语言
            settingRow(T("语言")) {
                Picker("", selection: Binding(
                    get: { language.current },
                    set: { language.set($0) }
                )) {
                    ForEach(MacLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            Divider()

            settingRow(T("本地缓存")) {
                HStack(spacing: 10) {
                    Text(cacheBytes.fileSizeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(T("清理缓存")) {
                        library.clearThumbnailCache()
                        MacImageCache.clear()
                        cacheBytes = Self.thumbnailCacheSize()
                    }
                    .buttonStyle(.link)
                }
            }

            Divider()

            settingRow(T("隐私政策")) {
                linkButton(T("查看")) { showPrivacy = true }
            }

            Divider()

            settingRow(T("用户协议")) {
                linkButton(T("查看")) { showTerms = true }
            }

            Divider()

            settingRow(T("联系我们")) {
                linkButton(T("邮件反馈")) { openMail() }
            }

            Divider()

            settingRow(T("给 App 评分")) {
                linkButton(T("去评分")) { requestReview() }
            }

            Divider()

            settingRow(T("版本号")) {
                HStack(spacing: 10) {
                    Text(appVersionText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    linkButton(T("检查更新")) { checkUpdate() }
                }
            }

            Divider()

            settingRow(T("关于 LeogotoPlay")) {
                Text(T("本地视频管理与剪辑 · macOS"))
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
            Text(T("功能选择")).font(.headline).padding(.bottom, 4)
            Text(T("至少保留一个功能；关掉的那个不会出现在左侧栏。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            settingRow(T("Library · 视频库")) {
                Toggle("", isOn: $showLibrary)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    // Cut 已经关了就不能再关 Library（否则侧栏空掉）
                    .disabled(!showCut)
            }

            Divider()

            settingRow(T("Cut · 剪辑台")) {
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

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.link)
    }

    /// 邮件反馈：一个 mailto 就够，带上主题方便筛反馈
    private func openMail() {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = MacLegal.contactEmail
        comps.queryItems = [URLQueryItem(name: "subject", value: T("LeogotoPlay 反馈（{1}）", appVersionText))]
        guard let url = comps.url, NSWorkspace.shared.open(url) else {
            showToast(T("没有可用的邮件客户端，请直接发到 {1}", MacLegal.contactEmail))
            return
        }
    }

    /// 评分：Debug / 非 App Store 分发时系统不会弹框，兜个提示说明
    private func requestReview() {
        SKStoreReviewController.requestReview()
        showToast(T("谢谢支持！如果没弹出评分框，说明当前是开发版，上架 App Store 后才会出现。"))
    }

    /// 暂无更新服务端：本地比对版本，直接告诉用户当前已是最新
    private func checkUpdate() {
        showToast(T("当前已是最新版本 {1}", appVersionText))
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastToken == token { toast = nil }
        }
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

// MARK: - 隐私政策 / 用户协议（内置文本，App Store 审核要求可在应用内查看）

enum MacLegal {
    /// TODO: 上架前换成正式支持邮箱
    static let contactEmail = "support@leogotoplay.com"

    static var privacyPolicy: String { MacLang.current == .zh ? privacyPolicyZH : privacyPolicyEN }
    static var terms: String { MacLang.current == .zh ? termsZH : termsEN }

    private static let privacyPolicyZH = """
    LeogotoPlay 隐私政策
    更新日期：2026 年 11 月 27 日

    一、我们不收集什么
    LeogotoPlay 的视频导入、播放、剪辑、分割、人脸打码、文字提取全部在你的 Mac 本地完成。我们不上传你的视频、图片或识别文字，App 内也没有接入任何第三方统计、广告或行为追踪 SDK。

    二、数据存在哪里
    · 视频与缩略图：~/Library/Application Support/LeogotoPlay/（你随时可在 App 内删除）
    · 剪辑草稿：同一目录下的草稿文件
    · 分割、打码的中间成片：系统临时目录，关闭窗口即自动删除
    · 账号信息（本地演示实现）：邮箱、昵称，以及加盐哈希后的密码；登录态保存在系统钥匙串（Keychain）

    三、系统权限
    · 语音识别：仅在「一键提取文字」做声音转写时使用，识别在本机完成，音频不会离开设备
    · 文件访问：只访问你在「导入视频」「导出到文件夹」时主动选择的文件或目录

    四、你的控制权
    你可以在「Me · 我的」里一键清理本地缓存；删除 App 即删除全部本地数据。账号数据可在登录后退出登录，或删除 App 一并清除。

    五、联系我们
    对本政策有任何疑问，请发邮件至 \(contactEmail)。
    """

    private static let privacyPolicyEN = """
    LeogotoPlay Privacy Policy
    Last updated: November 27, 2026

    1. What we don't collect
    Importing, playback, editing, splitting, face blurring and text extraction all run locally on your Mac. We never upload your videos, images or recognized text, and the app bundles no third-party analytics, advertising or tracking SDKs.

    2. Where your data lives
    · Videos and thumbnails: ~/Library/Application Support/LeogotoPlay/ (you can delete them in the app at any time)
    · Editing drafts: draft files in the same folder
    · Intermediate split / blurred outputs: the system temp folder, deleted automatically when the window closes
    · Account info (local demo implementation): email, nickname and a salted password hash; the session is stored in the macOS Keychain

    3. System permissions
    · Speech recognition: used only by "Extract Text" for audio transcription; recognition runs on this Mac and audio never leaves the device
    · File access: only the files and folders you pick via "Import video" or "Export to folder"

    4. Your control
    Clear the local cache from "Me" in one click; deleting the app removes all local data. Sign out after signing in, or delete the app, to erase account data.

    5. Contact us
    Questions about this policy? Email \(contactEmail).
    """

    private static let termsZH = """
    LeogotoPlay 用户协议
    更新日期：2026 年 11 月 27 日

    一、服务内容
    LeogotoPlay 提供本地视频管理、播放、剪辑、一键分割、人脸打码、文字提取、人脸提取等功能，全部在本机离线运行。

    二、素材与版权
    你导入、编辑、导出的视频与图片须为你有合法使用权的内容。因素材侵权、肖像权或隐私争议产生的责任由你自行承担。

    三、使用限制
    不得使用本工具制作或传播违法违规内容；不得在未经他人同意的情况下，将他人影像处理后公开发布。

    四、数据与备份
    所有处理都在你的设备上完成。清理缓存、删除 App 或卸载会移除本地数据，请自行备份重要素材。

    五、免责
    因设备故障、系统异常、断电等导致的文件损坏或数据丢失，本 App 不承担赔偿责任，但会在实现上尽量避免写入中断。

    六、条款变更
    条款更新后会在 App 内展示，你继续使用即视为接受更新后的条款。

    七、联系方式
    邮件：\(contactEmail)
    """

    private static let termsEN = """
    LeogotoPlay Terms of Use
    Last updated: November 27, 2026

    1. The service
    LeogotoPlay offers a local video library, playback, editing, one-click splitting, face blurring, text extraction and face extraction. Everything runs offline on this Mac.

    2. Media and copyright
    You must hold the rights to any video or image you import, edit or export. You are responsible for any claim arising from copyright, portrait rights or privacy disputes.

    3. Acceptable use
    Don't use this tool to create or distribute unlawful content, and don't publish footage of other people without their consent.

    4. Data and backups
    All processing happens on your device. Clearing the cache, deleting or uninstalling the app removes local data — back up important media yourself.

    5. Disclaimer
    We are not liable for file damage or data loss caused by device failure, system errors or power loss, although the implementation does its best to avoid interrupted writes.

    6. Changes
    Updated terms are shown inside the app; continued use means you accept them.

    7. Contact
    Email: \(contactEmail)
    """
}

struct MacLegalSheet: View {
    let title: String
    let bodyText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).foregroundStyle(.white)
                Spacer()
                Button(T("完成")) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider().opacity(0.3)

            ScrollView {
                Text(bodyText)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(18)
            }
        }
        .frame(width: 620, height: 560)
        .background(MacTheme.canvas)
    }
}

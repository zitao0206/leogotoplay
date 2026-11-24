import PhotosUI
import SwiftUI
import UIKit
import LeogotoPlayCore

/// V3.5：一键提取文字页面。
/// 流程：选片 → 估时确认 → 处理（蒙版 + 进度，提示别锁屏/切后台）→ 结果列表（可复制）。
struct TextExtractView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TextExtractPrefs.framesKey) private var includeScreen = true
    @AppStorage(TextExtractPrefs.speechKey) private var includeSpeech = true

    @State private var photoItem: PhotosPickerItem?
    @State private var tempURL: URL?
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimateLabel = ""
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var phaseText = "准备中…"
    @State private var result: TextExtractResult?
    @State private var showResult = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showCancelProcessing = false
    private let processingTaskBox = ProcessingTaskBox()

    /// Debug 用：直接拿一个本地视频跑整条链路（模拟器里没法操作系统相册选片器）
    private let debugURL: URL?

    init(debugURL: URL? = nil) {
        self.debugURL = debugURL
    }

    var body: some View {
        ZStack {
            navigationContent
            if isProcessing {
                processingMask
            }
        }
        .toolbar(isProcessing ? .hidden : .visible, for: .navigationBar)
        .interactiveDismissDisabled(isProcessing)
        .modifier(SheetBackground(isDark: isProcessing))
    }

    private var navigationContent: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    introCard
                    addCard
                    optionCard
                    noteCard
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("一键提取文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await prepare(item) }
            }
            .onAppear { debugAutoRunIfNeeded() }
            .alert("开始提取？", isPresented: $showConfirm) {
                Button("开始提取") { Task { @MainActor in start() } }
                Button("取消", role: .cancel) { cleanupTemp() }
            } message: {
                Text("预计需要\(estimateLabel)。处理期间会保持屏幕常亮，请不要锁屏或切换 App。")
            }
            .alert("提取失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay {
                // 预留：结果 sheet 之外的浮层
            }
            .sheet(isPresented: $showResult) { resultSheet }
            .toast($toastMessage)
            .onDisappear {
                if !isProcessing { cleanupTemp() }
            }
        }
    }

    // MARK: - 介绍

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("一键提取视频里的文字")
                        .font(.headline)
                    Text("画面字幕 + 声音，一次全部转成文本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("把画面里出现的字幕、贴片文字逐帧识别出来")
                bullet("把视频里的说话内容转成文字，带时间码")
                bullet("可以只取其中一种，也可以两种一起要")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.accent.opacity(0.6))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 选片

    private var addCard: some View {
        PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
            VStack(spacing: 10) {
                Image(systemName: isPreparing ? "hourglass" : "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.accent.opacity(0.12))
                    )
                Text(isPreparing ? "读取视频中…" : "从相册中选片")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("只做识别，不会改动原视频，也不会上传")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparing || isProcessing)
    }

    // MARK: - 提取内容

    private var optionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "提取内容", subtitle: "至少保留一项")

            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { includeScreen },
                    set: { newValue in
                        // 两个不能同时关掉
                        if !newValue && !includeSpeech { return }
                        includeScreen = newValue
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("画面字幕文字")
                            .font(.subheadline.weight(.medium))
                        Text("识别画面里出现的字幕与贴片文字")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)

                Divider().padding(.leading, 2)

                Toggle(isOn: Binding(
                    get: { includeSpeech },
                    set: { newValue in
                        if !newValue && !includeScreen { return }
                        includeSpeech = newValue
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("声音转文字")
                            .font(.subheadline.weight(.medium))
                        Text("把说话内容转写出来，带时间码")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )

            Text("这个设置会记在这台手机上，下次进来还是你的选择。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("识别只认画面里看得见的字，视频里自带的独立字幕轨道读不到；音乐、多人抢话、方言会降低声音转写的准确度，结果建议再核对一遍。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 处理蒙版

    private var processingMask: some View {
        ZStack {
            Color(red: 0.052, green: 0.052, blue: 0.058)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}   // 吃掉点击，避免误触

            VStack(spacing: 0) {
                HStack {
                    Button {
                        showCancelProcessing = true
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.leading, 6)
                .padding(.top, 4)

                Spacer(minLength: 0)

                VStack(spacing: 30) {
                    ProcessingOrb()

                    VStack(spacing: 12) {
                        Text("文字提取中 \(Int(progress * 100))%")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("\(phaseText)，请不要锁屏或切换程序")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.42))
                            .multilineTextAlignment(.center)
                    }
                }
                .offset(y: -36)

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .transition(.opacity)
        .alert("停止提取？", isPresented: $showCancelProcessing) {
            Button("停止提取", role: .destructive) {
                Task { @MainActor in cancelProcessing() }
            }
            Button("继续", role: .cancel) {}
        } message: {
            Text("已经识别出来的文字会一并丢弃，视频本身不受影响。")
        }
    }

    // MARK: - 结果

    private var resultSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result {
                    if result.lines.isEmpty {
                        EmptyStateView(
                            symbol: "text.magnifyingglass",
                            title: "没提取到文字",
                            message: "这个视频里没有识别到可见的字幕，声音也没转出内容。"
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if !result.warnings.isEmpty {
                                    ForEach(result.warnings, id: \.self) { warning in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.accent)
                                            Text(warning)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.bottom, 4)
                                }

                                ForEach(result.lines) { line in
                                    lineRow(line)
                                }
                            }
                            .padding(Theme.pagePadding)
                        }
                    }

                    copyBar(result)
                }
            }
            .navigationTitle("提取结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showResult = false }
                }
            }
        }
        .toast($toastMessage)
    }

    private func lineRow(_ line: ExtractedLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(line.timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(line.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(line.source == .screen ? Theme.accent : .blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (line.source == .screen ? Theme.accent : Color.blue).opacity(0.12),
                        in: Capsule()
                    )
            }
            Text(line.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func copyBar(_ result: TextExtractResult) -> some View {
        VStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = result.plainText
                toastMessage = "已复制 \(result.lines.count) 条文字"
            } label: {
                Label("复制全部文字", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fillsWidth: true))

            Text("共 \(result.lines.count) 条 · 画面 \(result.screenCount) / 语音 \(result.speechCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: - 流程

    private func prepare(_ item: PhotosPickerItem) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let url = try await VideoImporter.prepare(from: item)
            await configure(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func configure(url: URL, autoStart: Bool = false) async {
        cleanupTemp()
        tempURL = url
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        estimateLabel = TextExtractor.estimateLabel(
            TextExtractor.estimate(duration: duration, includeScreen: includeScreen, includeSpeech: includeSpeech)
        )
        if autoStart {
            start()
        } else {
            showConfirm = true
        }
    }

    @MainActor
    private func start() {
        guard let url = tempURL else { return }
        isProcessing = true
        progress = 0
        phaseText = "准备中…"
        UIApplication.shared.isIdleTimerDisabled = true

        processingTaskBox.task = Task {
            do {
                let res = try await TextExtractor.run(
                    url: url,
                    includeScreen: includeScreen,
                    includeSpeech: includeSpeech
                ) { value, phase in
                    Task { @MainActor in
                        progress = value
                        phaseText = phase
                    }
                }
                await MainActor.run {
                    guard !processingTaskBox.cancelledFlag else { return }
                    isProcessing = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    result = res
                    showResult = true
                    cleanupTemp()
                }
            } catch {
                await MainActor.run {
                    guard !processingTaskBox.cancelledFlag else { return }
                    isProcessing = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    errorMessage = error.localizedDescription
                    cleanupTemp()
                }
            }
        }
    }

    @MainActor
    private func cancelProcessing() {
        processingTaskBox.cancelledFlag = true
        processingTaskBox.task?.cancel()
        processingTaskBox.task = nil
        isProcessing = false
        progress = 0
        UIApplication.shared.isIdleTimerDisabled = false
        cleanupTemp()
    }

    private func cleanupTemp() {
        if let url = tempURL {
            VideoImporter.cleanTemporaryFile(at: url)
            tempURL = nil
        }
    }

    // MARK: - Debug

    private func debugAutoRunIfNeeded() {
        #if DEBUG
        guard let url = debugURL, tempURL == nil else { return }
        let skipConfirm = UserDefaults.standard.bool(forKey: "textExtractSkipConfirm")
        Task { await configure(url: url, autoStart: skipConfirm) }
        #endif
    }
}


/// 处理中把 sheet 自身底色也刷黑，否则顶部会露出浅色圆角条（iOS 16.4 起才支持动态底色）
struct SheetBackground: ViewModifier {
    let isDark: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(
                isDark
                ? Color(red: 0.052, green: 0.052, blue: 0.058)
                : Color(uiColor: .systemGroupedBackground)
            )
        } else {
            content
        }
    }
}

/// 处理任务的持有盒：既能取消，也能让完成回调识别「这次是被用户取消的」
final class ProcessingTaskBox {
    var task: Task<Void, Never>?
    var cancelledFlag = false
}

/// 处理中的光球：白球 + 内部主题暖色流光（主色 #FF5C3D → #FF9A6B → 浅橙），缓慢自转
struct ProcessingOrb: View {
    @State private var angle: Double = 0
    @State private var breathe = false

    private let warmFlow = AngularGradient(
        colors: [
            Theme.accent,
            Color(red: 1.0, green: 0.42, blue: 0.30),
            Theme.accentSecondary,
            Color(red: 1.0, green: 0.84, blue: 0.74),
            Theme.accentSecondary,
            Theme.accent
        ],
        center: .center,
        angle: .degrees(20)
    )

    var body: some View {
        ZStack {
            // 外层白色泛光
            Circle()
                .fill(Color.white.opacity(0.38))
                .frame(width: 148, height: 148)
                .blur(radius: 40)

            // 球体本身：白色壳
            Circle()
                .fill(.white)
                .frame(width: 120, height: 120)
                .overlay {
                    // 内部流光：整体略缩小，留出白边
                    Circle()
                        .fill(warmFlow)
                        .frame(width: 86, height: 86)
                        .rotationEffect(.degrees(angle))
                        .blur(radius: 4)
                        .opacity(0.96)
                }
                .overlay {
                    // 顶部柔光，制造玻璃球的立体感
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.5), .white.opacity(0.0)],
                                center: .init(x: 0.36, y: 0.28),
                                startRadius: 1,
                                endRadius: 56
                            )
                        )
                        .frame(width: 86, height: 86)
                        .mask(Circle().frame(width: 86, height: 86))
                }
                .overlay {
                    // 内壁描边
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 3.5)
                        .blur(radius: 5)
                }
                .shadow(color: .white.opacity(0.35), radius: 22)
                .scaleEffect(breathe ? 1.03 : 0.97)
        }
        .frame(width: 160, height: 160)
        .onAppear {
            withAnimation(.linear(duration: 11).repeatForever(autoreverses: false)) {
                angle = 360
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

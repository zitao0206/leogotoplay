import AVFoundation
import AVKit
import LeogotoPlayCore
import PhotosUI
import SwiftUI

/// V3.6：用 fullScreenCover(item:) 承载打码页，避免 sheet 顶部露出父页底色
struct FaceMaskRequest: Identifiable {
    let id = UUID()
    let url: URL?
}

/// V3.6：Cut 热门工具「一键人脸打码」页面
struct FaceMaskView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(FaceMaskPrefs.styleKey) private var styleRaw = FaceMaskStyle.pixelate.rawValue

    @State private var photoItem: PhotosPickerItem?
    @State private var tempURL: URL?
    @State private var sourceDuration: Double = 0
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimateLabel = ""
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var phaseText = "正在定位人脸"
    @State private var result: FaceMaskResult?
    @State private var showCancelProcessing = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var isSaving = false

    // 用 @State 持有，保证 SwiftUI 重绘时取消仍能命中正在运行的那个 Task
    @State private var taskBox = ProcessingTaskBox()
    private let debugURL: URL?

    init(debugURL: URL? = nil) {
        self.debugURL = debugURL
    }

    private var style: FaceMaskStyle {
        FaceMaskStyle(rawValue: styleRaw) ?? .pixelate
    }

    var body: some View {
        ZStack {
            if let result {
                resultScreen(result)
            } else {
                setupScreen
            }
            if isProcessing {
                processingMask
            }
        }
        .modifier(SheetBackground(isDark: isProcessing))
        .toast($toastMessage)
    }

    // MARK: - 选片页

    private var setupScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    introCard
                    addCard
                    styleCard
                    noteCard
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("一键人脸打码")
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
            .alert("开始打码？", isPresented: $showConfirm) {
                Button("开始打码") { Task { @MainActor in start() } }
                Button("取消", role: .cancel) { cleanupTemp() }
            } message: {
                Text("预计需要\(estimateLabel)。处理期间请不要锁屏或切换 App，否则会中断。")
            }
            .alert("打码失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear {
                if !isProcessing { cleanupTemp() }
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "face.dashed")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("一键人脸打码")
                        .font(.headline)
                    Text("自动找到画面里的人脸，按你选的方式遮住")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("逐帧检测人脸位置，整段视频里的人都会被遮住")
                bullet("四种遮挡方式，块大小和模糊半径都跟着脸宽走")
                bullet("全程在本机处理，原视频不动，也不会上传")
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
                Text("选一段视频，处理好后生成一个打码新片")
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

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "打码方式", subtitle: "四种任选一种，会记住上次的选择")

            VStack(spacing: 0) {
                ForEach(FaceMaskStyle.allCases) { option in
                    Button {
                        styleRaw = option.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(option == style ? Theme.accent : .secondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill((option == style ? Theme.accent : Color.secondary).opacity(0.12))
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: option == style ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(option == style ? Theme.accent : Color.secondary.opacity(0.35))
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if option != FaceMaskStyle.allCases.last {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("打码要重新编码整段视频，画质会有轻微损失。侧脸、被手挡住的脸、画面里很小的人脸可能漏检，重要素材建议先看一遍结果。")
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
                .onTapGesture {}

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
                        Text("人脸打码中 \(Int(progress * 100))%")
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
        .alert("停止打码？", isPresented: $showCancelProcessing) {
            Button("停止打码", role: .destructive) {
                Task { @MainActor in cancelProcessing() }
            }
            Button("继续", role: .cancel) {}
        } message: {
            Text("这一段处理进度会丢弃，原视频不受影响。")
        }
    }

    // MARK: - 结果页

    private func resultScreen(_ result: FaceMaskResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") { dismiss() }
                    .font(.subheadline)
                Spacer()
                Text("打码完成")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await saveToAlbum(result) }
                } label: {
                    Text(isSaving ? "保存中…" : "保存")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .disabled(isSaving)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    infoChip(icon: "person.crop.circle", text: "检测到 \(result.faceCount) 个人")
                    infoChip(icon: "clock", text: "时长 \(result.duration.timecode)")
                    infoChip(icon: "paintbrush", text: result.style.title)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
                .padding(.horizontal, Theme.pagePadding)

                // 视频区域一直延伸到屏幕底部安全区
                FaceMaskPreview(url: result.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, Theme.pagePadding)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
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
        sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
        estimateLabel = FaceMasker.estimateLabel(
            FaceMasker.estimate(duration: sourceDuration, style: style)
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
        phaseText = "正在定位人脸"
        UIApplication.shared.isIdleTimerDisabled = true
        taskBox.cancelledFlag = false

        taskBox.task = Task {
            do {
                let res = try await FaceMasker.run(url: url, style: style) { value in
                    Task { @MainActor in
                        progress = value
                        phaseText = value > 0.55 ? "正在重新编码画面" : "正在定位并遮挡人脸"
                    }
                }
                await MainActor.run {
                    guard !taskBox.cancelledFlag else { return }
                    isProcessing = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    result = res
                    cleanupTemp()
                }
            } catch {
                await MainActor.run {
                    guard !taskBox.cancelledFlag else { return }
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
        taskBox.cancelledFlag = true
        taskBox.task?.cancel()
        taskBox.task = nil
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

    private func saveToAlbum(_ result: FaceMaskResult) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await VideoExporter.saveToAlbum(result.url)
            toastMessage = "已保存到相册"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Debug

    private func debugAutoRunIfNeeded() {
        #if DEBUG
        guard let url = debugURL, result == nil else { return }
        let skipConfirm = UserDefaults.standard.bool(forKey: "faceMaskSkipConfirm")
        Task { await configure(url: url, autoStart: skipConfirm) }
        #endif
    }
}

// MARK: - 结果预览（播放 + 可拖动进度条）

private struct FaceMaskPreview: View {
    let url: URL

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 10) {
            VideoLayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)

                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { min(time, max(duration, 0.01)) },
                            set: { newValue in
                                time = newValue
                                seek(to: newValue)
                            }
                        ),
                        in: 0...max(duration, 0.01),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            // 一碰进度条就暂停，松手也不自动续播，方便停下来看清某一帧有没有漏打
                            if editing {
                                player.pause()
                                isPlaying = false
                            }
                        }
                    )
                    .tint(Theme.accent)

                    HStack {
                        Text(time.timecode)
                        Spacer()
                        Text(duration.timecode)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let asset = AVURLAsset(url: url)
            Task {
                let seconds = (try? await asset.load(.duration).seconds) ?? 0
                await MainActor.run { duration = seconds }
            }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { current in
                guard !isScrubbing else { return }
                time = current.seconds
                if let item = player.currentItem, item.duration.seconds > 0,
                   current.seconds >= item.duration.seconds - 0.05 {
                    isPlaying = false
                }
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
    }

    private func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.1 { seek(to: 0); time = 0 }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

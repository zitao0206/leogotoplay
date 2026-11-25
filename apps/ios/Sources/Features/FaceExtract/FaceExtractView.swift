import AVFoundation
import LeogotoPlayCore
import PhotosUI
import SwiftUI
import UIKit

/// V3.8：用 fullScreenCover(item:) 承载提取页，和打码 / 增强页保持一致
struct FaceExtractRequest: Identifiable {
    let id = UUID()
    let url: URL?
}

/// V3.8：Cut 热门工具「一键提取人脸」
struct FaceExtractView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var tempURL: URL?
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimate: FaceExtractor.Estimate?
    @State private var frameInterval: Double = FaceExtractPrefs.frameInterval
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var result: FaceExtractResult?
    @State private var showCancelProcessing = false
    @State private var previewFace: ExtractedFace?
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let taskBox = ProcessingTaskBox()
    private let debugURL: URL?

    init(debugURL: URL? = nil) {
        self.debugURL = debugURL
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
            if showConfirm {
                confirmOverlay
            }
        }
        .modifier(SheetBackground(isDark: isProcessing))
        .toast($toastMessage)
        .fullScreenCover(item: $previewFace) { face in
            facePreview(face)
        }
    }

    // MARK: - 选片页

    private var setupScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    introCard
                    intervalCard
                    addCard
                    noteCard
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("一键提取人脸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: frameInterval) { value in
                saveInterval(value)
                FaceExtractPrefs.frameInterval = value
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await prepare(item) }
            }
            .onAppear { debugAutoRunIfNeeded() }
            .alert("提取失败", isPresented: Binding(
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
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("一键提取人脸")
                        .font(.headline)
                    Text("扫出视频里出现过的每一张脸，裁成图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("按设定的取帧间隔扫完整段视频，同一张脸只留最清楚的一张")
                bullet("按 3:4 竖图裁切，自带一点额头和头发，可以直接当头像用")
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

    private var intervalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("取帧间隔", systemImage: "speedometer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("每 \(Int(frameInterval)) 秒 1 帧")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }

            Slider(value: $frameInterval, in: 1...10, step: 1)
                .tint(Theme.accent)
                .disabled(isPreparing || isProcessing)

            HStack {
                Text("1 秒（最细）")
                Spacer()
                Text("10 秒（最省）")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("1 秒取 1 帧最不容易漏掉人脸，耗时也最长；往后每加 1 秒，抽检帧数和耗时约少一成，一闪而过的脸就更容易漏。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func saveInterval(_ value: Double) {
        frameInterval = min(max(value.rounded(), 1), 10)
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
                Text("选一段视频，处理好后把每张脸列出来")
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

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("侧脸、被手挡住的脸、画面里很小的路人脸可能抓不到。视频里出现的人越多、换人越频繁，提取出来的张数越多，最多保留 80 张；同一张脸只留质量最好的一帧。原视频不会被修改。")
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

    /// 开始前的确认卡片：把预估耗时放大、上主色，突出到一眼能看到
    private var confirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 14) {
                Text("开始提取人脸？")
                    .font(.headline)

                Text(estimate?.summary ?? "正在评估耗时…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    Text("按本机速度预计需要")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(estimate?.durationLabel ?? "几秒")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button {
                        showConfirm = false
                        cleanupTemp()
                    } label: {
                        Text("取消")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConfirm = false
                        Task { @MainActor in start() }
                    } label: {
                        Text("开始提取")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Theme.accent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: .black.opacity(0.18), radius: 26, y: 10)
            .padding(.horizontal, 30)
        }
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
                        Text("人脸提取中 \(Int(progress * 100))%")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("正在逐帧扫描人脸，请不要锁屏或切换程序")
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
            Text("已经扫过的部分会丢弃，原视频不受影响。")
        }
    }

    // MARK: - 结果页

    private func resultScreen(_ result: FaceExtractResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") { dismiss() }
                    .font(.subheadline)
                Spacer()
                Text("提取完成")
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

            HStack(spacing: 10) {
                infoChip(icon: "person.2", text: "共 \(result.faces.count) 张")
                infoChip(icon: "clock", text: "时长 \(result.duration.timecode)")
                infoChip(icon: "square.grid.3x3", text: "3:4 裁切")
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            .padding(.horizontal, Theme.pagePadding)

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(result.faces) { face in
                        Button {
                            previewFace = face
                        } label: {
                            Rectangle()
                                .fill(Color.black.opacity(0.06))
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .overlay {
                                    Image(uiImage: face.image)
                                        .resizable()
                                        .scaledToFill()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text(face.time.timecode)
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .padding(6)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 24)
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

    private func facePreview(_ face: ExtractedFace) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: face.image)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 12)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        previewFace = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
                Text("\(face.time.timecode)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 流程

    private func prepare(_ item: PhotosPickerItem) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let url = try await VideoImporter.prepare(from: item)
            await configure(url: url)
            // 清掉选中项，下次再选同一条视频也能重新触发
            photoItem = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func configure(url: URL, autoStart: Bool = false) async {
        cleanupTemp()
        tempURL = url
        // 先在本机实测一帧的检测速度，再折算整段耗时（模拟器和真机差好几倍）
        let measured = await FaceExtractor.estimate(url: url, frameInterval: frameInterval)
        estimate = measured
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
        UIApplication.shared.isIdleTimerDisabled = true
        taskBox.cancelledFlag = false

        taskBox.task = Task {
            do {
                let res = try await FaceExtractor.run(url: url, frameInterval: frameInterval) { value in
                    Task { @MainActor in
                        progress = value
                    }
                }
                await MainActor.run {
                    guard !taskBox.cancelledFlag else { return }
                    isProcessing = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    result = res
                    cleanupTemp()
                    #if DEBUG
                    // 截图钩子：-faceExtractAutoSave YES 出结果后自动存相册，方便验证批量保存
                    if UserDefaults.standard.bool(forKey: "faceExtractAutoSave") {
                        Task { @MainActor in await saveToAlbum(res) }
                    }
                    #endif
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

    @MainActor
    private func saveToAlbum(_ result: FaceExtractResult) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let count = try await FaceExtractor.save(faces: result.faces)
            toastMessage = "已保存 \(count) 张到相册"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Debug

    private func debugAutoRunIfNeeded() {
        #if DEBUG
        guard let url = debugURL, result == nil else { return }
        let skipConfirm = UserDefaults.standard.bool(forKey: "faceExtractSkipConfirm")
        Task { await configure(url: url, autoStart: skipConfirm) }
        #endif
    }
}

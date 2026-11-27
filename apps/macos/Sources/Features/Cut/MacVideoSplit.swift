import AppKit
import AVFoundation
import LeogotoPlayCore
import SwiftUI

// MARK: - 数据

enum MacVideoSplitPrefs {
    static let partsKey = "split.parts"
}

/// 分割出来的一段
struct MacSplitPart: Identifiable {
    let id = UUID()
    /// 第几段，从 1 开始
    let index: Int
    var start: Double
    var end: Double
    var url: URL?
    var fileSize: Int64 = 0

    var duration: Double { max(0, end - start) }
    var timeLabel: String { "\(splitStamp(start)) – \(splitStamp(end))" }
}

/// 带一位小数的时间码：00:03.3，半个字的差别在这类分段上比整秒更有用
func splitStamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = seconds - Double(h * 3600 + m * 60)
    if h > 0 {
        return String(format: "%d:%02d:%04.1f", h, m, s)
    }
    return String(format: "%02d:%04.1f", m, s)
}

enum MacVideoSplitError: LocalizedError {
    case tooShort
    case noVideoTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooShort: return "视频太短，分出来每段不到 1 秒了"
        case .noVideoTrack: return "这个视频没有可分割的画面轨道"
        case .exportFailed(let reason): return "分割失败：\(reason)"
        }
    }
}

struct MacSplitResult {
    var parts: [MacSplitPart]
    var tempDir: URL
    /// 原片名，导出时当文件名前缀
    var baseName: String

    var totalDuration: Double { parts.reduce(0) { $0 + $1.duration } }
}

// MARK: - 分割器

enum MacVideoSplitter {

    static let minParts = 2
    static let maxParts = 20
    /// 每段最短 1 秒，短于这个就没法分了
    static let minPartDuration = 1.0

    static func canSplit(duration: Double, parts: Int) -> Bool {
        parts >= minParts && parts <= maxParts && duration / Double(parts) >= minPartDuration
    }

    /// 按累计边界均分，最后一段吃掉取整余量，保证首尾对得上原片
    static func plan(duration: Double, parts: Int) -> [MacSplitPart] {
        guard parts > 0, duration > 0 else { return [] }
        var result: [MacSplitPart] = []
        for index in 0..<parts {
            let start = duration * Double(index) / Double(parts)
            let end = index == parts - 1 ? duration : duration * Double(index + 1) / Double(parts)
            result.append(MacSplitPart(index: index + 1, start: start, end: end))
        }
        return result
    }

    /// 纯转封装切割（不重编码，画质与体积都不变），失败再退回重编码
    static func run(
        url: URL,
        parts: Int,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> MacSplitResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false else {
            throw MacVideoSplitError.noVideoTrack
        }
        guard canSplit(duration: duration, parts: parts) else {
            throw MacVideoSplitError.tooShort
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var planned = plan(duration: duration, parts: parts)

        for index in planned.indices {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempDir)
                throw CancellationError()
            }
            let part = planned[index]
            let output = tempDir.appendingPathComponent("\(baseName)-\(part.index).mp4")
            onProgress(Double(index) / Double(parts), "正在切第 \(part.index) / \(parts) 段")

            let range = CMTimeRange(
                start: CMTime(seconds: part.start, preferredTimescale: 600),
                duration: CMTime(seconds: part.end - part.start, preferredTimescale: 600)
            )
            do {
                try await export(asset: asset, range: range, to: output)
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                throw MacVideoSplitError.exportFailed(error.localizedDescription)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
            planned[index].url = output
            planned[index].fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        onProgress(1.0, "分割完成")
        return MacSplitResult(parts: planned, tempDir: tempDir, baseName: baseName)
    }

    /// 先试透传（快、无损）；透传在个别封装上会失败，退回高质量重编码
    private static func export(asset: AVURLAsset, range: CMTimeRange, to url: URL) async throws {
        var lastError: Error?

        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            session.outputURL = url
            session.outputFileType = .mp4
            session.timeRange = range
            await session.export()
            if session.status == .completed, fileExists(url) { return }
            lastError = session.error
            try? FileManager.default.removeItem(at: url)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw lastError ?? MacVideoSplitError.exportFailed("这台机器不支持这种编码")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.timeRange = range
        await session.export()
        guard session.status == .completed, fileExists(url) else {
            throw session.error ?? lastError ?? MacVideoSplitError.exportFailed("导出没有完成")
        }
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 分割产生的临时文件在关窗时一并清掉
    static func cleanUp(_ result: MacSplitResult?) {
        guard let result else { return }
        try? FileManager.default.removeItem(at: result.tempDir)
    }

    // MARK: 估时

    static func estimate(duration: Double, parts: Int) -> TimeInterval {
        max(2, duration * 0.02 + Double(parts) * 0.6)
    }

    static func estimateLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "约 \(total) 秒" }
        let m = total / 60
        let r = total % 60
        return r == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(r) 秒"
    }
}

// MARK: - 独立窗口

@MainActor
final class MacVideoSplitWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacVideoSplitWindowManager()

    private var window: NSWindow?

    func open(library: LibraryStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "一键分割视频"
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 840, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let testPath = UserDefaults.standard.string(forKey: "videoSplitTestURL")
        let root = MacVideoSplitView(
            library: library,
            onClose: { [weak window] in window?.close() },
            debugURL: testPath.map { URL(fileURLWithPath: $0) }
        )
        .tint(MacTheme.accent)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 页面

struct MacVideoSplitView: View {
    @ObservedObject var library: LibraryStore
    var onClose: () -> Void
    var debugURL: URL?

    @AppStorage(MacVideoSplitPrefs.partsKey) private var parts = 2

    @State private var sourceURL: URL?
    @State private var sourceDuration: Double = 0
    @State private var isPreparing = false
    @State private var showConfirm = false
    @State private var estimateText = ""
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var phaseText = "准备中…"
    @State private var result: MacSplitResult?
    @State private var previewPart: MacSplitPart?
    @State private var player: AVPlayer?
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var errorMessage: String?
    @State private var showCancelAlert = false
    @State private var isSaving = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MacTheme.canvas.ignoresSafeArea()

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
            if previewPart != nil {
                previewOverlay
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.82), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .padding(.bottom, 22)
                }
            }
        }
        .task { await autoStartIfNeeded() }
        .alert("分割失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("停止分割？", isPresented: $showCancelAlert) {
            Button("停止分割", role: .destructive) { cancelProcessing() }
            Button("继续", role: .cancel) {}
        } message: {
            Text("已经切好的片段会一并丢掉，原视频不受影响。")
        }
    }

    // MARK: 选片页

    private var setupScreen: some View {
        VStack(spacing: 0) {
            header(title: "一键分割视频", trailing: nil)

            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    pickCard
                    partsCard
                    planCard
                    noteCard
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.vertical, 16)
                .padding(.bottom, 16)
            }

            bottomBar
        }
    }

    private func header(title: String, trailing: AnyView?) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, MacTheme.pagePadding)
        .padding(.vertical, 12)
        .background(MacTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "scissors")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("把一条长视频切成几段")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("按时长均分，每段都是能单独播放的文件")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("默认切 2–6 份，也可以手动分到 20 份")
                bullet("原样切割：不重新编码，画质和清晰度不变")
                bullet("每段不到 1 秒时会拦住，建议去剪辑页面手动改")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(MacTheme.accent.opacity(0.6))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pickCard: some View {
        Button {
            Task { @MainActor in pickVideo() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: isPreparing ? "hourglass" : (sourceURL == nil ? "plus" : "checkmark"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(MacTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(MacTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let sourceURL {
                    Text(sourceURL.lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("时长 \(splitStamp(sourceDuration)) · 点一下换别的视频")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                } else {
                    Text(isPreparing ? "读取视频中…" : "选择一个视频文件")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("只读取，不改动原视频")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.28), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparing || isProcessing)
    }

    private var partsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("分成几份", systemImage: "square.split.2x1")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("最多 \(MacVideoSplitter.maxParts) 份")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            HStack(spacing: 8) {
                ForEach([2, 3, 4, 5, 6], id: \.self) { value in
                    Button {
                        parts = value
                    } label: {
                        Text("\(value) 份")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(parts == value ? .white : Color.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(parts == value ? MacTheme.accent : Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                Text("手动份数")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                stepperButton("minus") { parts = max(MacVideoSplitter.minParts, parts - 1) }
                Text("\(parts) 份")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 46)
                stepperButton("plus") { parts = min(MacVideoSplitter.maxParts, parts + 1) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(symbol == "minus" ? parts <= MacVideoSplitter.minParts : parts >= MacVideoSplitter.maxParts)
        .opacity(symbol == "minus" && parts <= MacVideoSplitter.minParts ? 0.4 : 1)
        .opacity(symbol == "plus" && parts >= MacVideoSplitter.maxParts ? 0.4 : 1)
    }

    /// 分段预览 + 太短提示
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("分段预览", systemImage: "list.number")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                if sourceDuration > 0 {
                    Text("每段约 \(partDurationText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }

            if sourceURL == nil {
                Text("先选一个视频，这里会列出切完的每一段。")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.4))
            } else {
                if isTooShort {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(MacTheme.accent)
                        Text("视频长度太短：\(splitStamp(sourceDuration)) 分成 \(parts) 份，每段不到 1 秒。建议去剪辑页面手动编辑。")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(plannedParts) { part in
                            HStack(spacing: 10) {
                                Text("\(part.index)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .frame(width: 22)
                                Text(part.timeLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.45))
                                Spacer()
                                Text(part.duration.shortDuration)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("说明", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("切割按关键帧对齐，个别位置会差一两帧（0.1 秒以内）；每段都会保留原片的画面和声音。切完的文件要「存入视频库」或「导出到文件夹」才会留下来。")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if isTooShort {
                Label("视频太短，不能这么分", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer()
            Button("开始分割") {
                begin()
            }
            .buttonStyle(MacSplitAccentButtonStyle())
            .disabled(sourceURL == nil || isPreparing || isTooShort)
            .opacity(sourceURL == nil || isTooShort ? 0.5 : 1)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, MacTheme.pagePadding)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    // MARK: 计算

    private var isTooShort: Bool {
        sourceURL != nil && sourceDuration > 0 && sourceDuration / Double(parts) < MacVideoSplitter.minPartDuration
    }

    private var plannedParts: [MacSplitPart] {
        MacVideoSplitter.plan(duration: sourceDuration, parts: parts)
    }

    private var partDurationText: String {
        (sourceDuration / Double(parts)).shortDuration
    }

    // MARK: 确认 / 处理

    private var confirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {}

            VStack(spacing: 14) {
                Text("分成 \(parts) 段？")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("时长 \(splitStamp(sourceDuration)) · 每段约 \(partDurationText)")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))

                VStack(spacing: 2) {
                    Text("预计需要")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text(estimateText.isEmpty ? "几秒" : estimateText)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacTheme.accent)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)

                Text("原视频不会被改动，分段先落在临时目录。")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.42))

                HStack(spacing: 10) {
                    Button {
                        showConfirm = false
                    } label: {
                        Text("取消")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConfirm = false
                        start()
                    } label: {
                        Text("开始分割")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(MacTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(width: 350)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
        }
    }

    private var processingMask: some View {
        ZStack {
            Color(red: 0.052, green: 0.052, blue: 0.058)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .controlSize(.large)
                    .tint(MacTheme.accent)
                Text("视频分割中 \(Int(progress * 100))%")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(phaseText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.42))

                ProgressView(value: progress)
                    .frame(width: 280)
                    .tint(MacTheme.accent)

                Button("停止分割") { showCancelAlert = true }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }

    // MARK: 结果页

    private func resultScreen(_ result: MacSplitResult) -> some View {
        VStack(spacing: 0) {
            header(
                title: "分割结果",
                trailing: AnyView(
                    HStack(spacing: 10) {
                        Button("存入视频库") {
                            saveToLibrary(result)
                        }
                        .buttonStyle(MacSplitAccentButtonStyle())
                        .disabled(isSaving)
                        Button("导出到文件夹…") {
                            exportToFolder(result)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                        Button("关闭") { closeWindow() }
                            .buttonStyle(.bordered)
                    }
                )
            )

            HStack(spacing: 10) {
                infoChip(icon: "square.split.2x1", text: "共 \(result.parts.count) 段")
                infoChip(icon: "clock", text: "原片 \(result.totalDuration.timecode)")
                infoChip(icon: "clock.badge.checkmark", text: "每段约 \(partDurationText)")
                Spacer()
                Button("重新分割") {
                    MacVideoSplitter.cleanUp(self.result)
                    self.result = nil
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, MacTheme.pagePadding)
            .padding(.vertical, 10)

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(MacTheme.accent)
                    Text(phaseText)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(result.parts) { part in
                        partRow(part)
                    }
                }
                .padding(.horizontal, MacTheme.pagePadding)
                .padding(.bottom, 20)
            }
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(text).font(.caption2)
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func partRow(_ part: MacSplitPart) -> some View {
        HStack(spacing: 12) {
            Text("\(part.index)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(MacTheme.accent)
                .frame(width: 26, height: 26)
                .background(MacTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("第 \(part.index) 段")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text("\(part.timeLabel) · \(part.duration.shortDuration) · \(part.fileSize.fileSizeText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer()

            Button {
                preview(part)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("预览这一段")

            Button {
                revealInFinder(part)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("在 Finder 里定位")
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var previewOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { closePreview() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("第 \(previewPart?.index ?? 1) 段预览")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        closePreview()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if let player {
                    MacPlayerSurface(player: player)
                        .frame(height: 420)
                }

                HStack(spacing: 10) {
                    Button {
                        if (player?.rate ?? 0) == 0 {
                            player?.play()
                        } else {
                            player?.pause()
                        }
                    } label: {
                        Image(systemName: (player?.rate ?? 0) == 0 ? "play.fill" : "pause.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                    Text(previewPart?.timeLabel ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 760)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
    }

    // MARK: 流程

    private func autoStartIfNeeded() async {
        guard let debugURL, result == nil, !isProcessing, !isPreparing, sourceURL == nil else { return }
        if let raw = UserDefaults.standard.string(forKey: "videoSplitParts"), let value = Int(raw) {
            parts = min(MacVideoSplitter.maxParts, max(MacVideoSplitter.minParts, value))
        }
        await configure(url: debugURL, autoStart: UserDefaults.standard.bool(forKey: "videoSplitSkipConfirm"))
    }

    @MainActor
    private func pickVideo() {
        guard let url = MacAlerts.chooseVideoFile() else { return }
        Task { await configure(url: url, autoStart: false) }
    }

    @MainActor
    private func configure(url: URL, autoStart: Bool) async {
        isPreparing = true
        sourceURL = url
        let asset = AVURLAsset(url: url)
        sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
        estimateText = MacVideoSplitter.estimateLabel(
            MacVideoSplitter.estimate(duration: sourceDuration, parts: parts)
        )
        isPreparing = false
        if autoStart {
            start()
        } else if !isTooShort {
            showConfirm = true
        }
    }

    private func begin() {
        guard sourceURL != nil, !isTooShort else { return }
        estimateText = MacVideoSplitter.estimateLabel(
            MacVideoSplitter.estimate(duration: sourceDuration, parts: parts)
        )
        showConfirm = true
    }

    private func start() {
        guard let url = sourceURL else { return }
        isProcessing = true
        progress = 0
        phaseText = "准备中…"
        runTask = Task {
            do {
                let res = try await MacVideoSplitter.run(url: url, parts: parts) { value, phase in
                    Task { @MainActor in
                        progress = value
                        phaseText = phase
                    }
                }
                await MainActor.run {
                    isProcessing = false
                    result = res
                    phaseText = ""
                }
            } catch is CancellationError {
                await MainActor.run { isProcessing = false }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelProcessing() {
        runTask?.cancel()
        runTask = nil
        isProcessing = false
        progress = 0
    }

    private func preview(_ part: MacSplitPart) {
        guard let url = part.url else { return }
        let player = AVPlayer(url: url)
        self.player = player
        previewPart = part
        player.play()
    }

    private func closePreview() {
        player?.pause()
        player = nil
        previewPart = nil
    }

    private func closeWindow() {
        closePreview()
        MacVideoSplitter.cleanUp(result)
        onClose()
    }

    private func revealInFinder(_ part: MacSplitPart) {
        guard let url = part.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveToLibrary(_ result: MacSplitResult) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            var saved = 0
            for part in result.parts {
                guard let url = part.url else { continue }
                await MainActor.run { phaseText = "正在存入视频库 \(part.index) / \(result.parts.count)" }
                do {
                    _ = try await library.importExport(fileURL: url, title: "\(result.baseName) \(part.index)")
                    saved += 1
                } catch {
                    await MainActor.run { errorMessage = "第 \(part.index) 段存入失败：\(error.localizedDescription)" }
                    break
                }
            }
            await MainActor.run {
                isSaving = false
                phaseText = ""
                if saved > 0 { showToast("已存入视频库 \(saved) 段") }
            }
        }
    }

    private func exportToFolder(_ result: MacSplitResult) {
        let panel = NSOpenPanel()
        panel.title = "选择保存文件夹"
        panel.prompt = "导出到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        isSaving = true
        Task {
            var exported = 0
            for part in result.parts {
                guard let url = part.url else { continue }
                let dest = dir.appendingPathComponent("\(result.baseName)-\(part.index).mp4")
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                    exported += 1
                } catch {
                    await MainActor.run { errorMessage = "第 \(part.index) 段导出失败：\(error.localizedDescription)" }
                    break
                }
            }
            await MainActor.run {
                isSaving = false
                if exported > 0 {
                    showToast("已导出 \(exported) 个文件")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toastToken == token { toast = nil }
        }
    }
}

private struct MacSplitAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MacTheme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
    }
}

import AppKit
import SwiftUI
import LeogotoPlayCore

// MARK: - 缩略图

/// macOS 端缩略图缓存：读盘 -> NSImage -> NSCache。
enum MacImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let url = VideoFileStore.shared.thumbnailURL(named: name)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}

struct MacThumbnailView: View {
    let thumbnailName: String?
    var cornerRadius: CGFloat = MacTheme.cardRadius

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x2A2B31), Color(hex: 0x3A3230)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "video.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: thumbnailName) {
            image = MacImageCache.thumbnail(named: thumbnailName)
        }
    }
}

// MARK: - 卡片

struct MacVideoCard<MenuContent: View>: View {
    let item: VideoItem
    var onPlay: () -> Void
    var onEdit: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    @ViewBuilder var menuContent: MenuContent

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 用无内在尺寸的 Color.clear 定 16:10 比例，缩略图放 overlay：
                // 竖屏素材直接贴在缩略图上会把卡片撑高（长宽比被素材反向决定）
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        // GeometryReader 一定按父级给的尺寸布局，素材再怎么长宽比都撑不大
                        GeometryReader { geo in
                            MacThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 8)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(item.duration.timecode)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(MacTheme.accent, in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .center) {
                if hovering {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(item.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(item.fileSize.fileSizeText) · \(item.duration.timecode) · \(item.source == .editor ? "剪辑导出" : "本地导入")")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : MacTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.16 : 0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous))
        .overlay {
            MacPressHoldOverlay(
                onTap: onPlay,
                onLongPress: { onLongPress?() },
                onSecondary: { onLongPress?() },
                onHoverChange: { hovering = $0 }
            )
            .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous))
        }
        .help("单击播放，右键更多操作")
    }
}

struct MacFolderCard: View {
    let folder: VideoFolder
    let videoCount: Int
    let coverThumbnails: [String?]
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(MacTheme.accent)
                Text(folder.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                if coverThumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                        .frame(height: 56)
                        .overlay(Image(systemName: "film.stack").foregroundStyle(.secondary))
                } else {
                    ForEach(Array(coverThumbnails.prefix(3).enumerated()), id: \.offset) { _, name in
                        MacThumbnailView(thumbnailName: name, cornerRadius: 6)
                            .frame(maxWidth: .infinity, maxHeight: 56)
                            .clipped()
                    }
                }
            }
            .frame(height: 56)

            Text("\(videoCount) 个视频")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(hovering ? 0.2 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .help("双击打开文件夹")
    }
}

// MARK: - 空状态

struct MacEmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(MacTheme.accent.opacity(0.8))
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - 工具

enum MacAlerts {
    /// 用 NSSavePanel 选一个导出位置。
    @MainActor
    static func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存导出视频"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 用 NSOpenPanel 选一个本地视频。
    @MainActor
    static func chooseVideoFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的视频"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func confirmDelete(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}


// MARK: - Library 列表行（V3.0.0：对齐 iOS 的一行一条式布局）

/// 行里用的日期格式（懒加载一次，泛型 struct 里不能放 static 存储属性）
private enum MacRowDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 文件夹行：图标 + 名字 + 「N 个视频 · M 个文件夹」+ 右侧箭头
struct MacFolderRow: View {
    let folder: VideoFolder
    let videoCount: Int
    let subfolderCount: Int
    var onOpen: () -> Void

    @State private var hovering = false

    private var detail: String {
        subfolderCount > 0
        ? "\(videoCount) 个视频 · \(subfolderCount) 个文件夹"
        : "\(videoCount) 个视频"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(MacTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(MacTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.16 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }
}

/// 视频行（列表布局）：缩略图 + 名字 + 「体积 · 日期 · 时长」，点一行就播放。
/// V3.1.15：去掉右侧 chevron 箭头（用户反馈导航指示符多余），并支持长按。
struct MacVideoRow<MenuContent: View>: View {
    let item: VideoItem
    var onPlay: () -> Void
    var onLongPress: (() -> Void)? = nil
    @ViewBuilder var menuContent: MenuContent

    @State private var hovering = false

    private var meta: String {
        "\(item.fileSize.fileSizeText) · \(MacRowDateFormatter.shared.string(from: item.createdAt)) · \(item.duration.timecode)"
    }

    var body: some View {
        HStack(spacing: 12) {
            MacThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 8)
                .frame(width: 56, height: 56)
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(MacTheme.accent)
                    }
                }
                Text(meta)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : MacTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.16 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .overlay {
            MacPressHoldOverlay(
                onTap: onPlay,
                onLongPress: { onLongPress?() },
                onSecondary: { onLongPress?() },
                onHoverChange: { hovering = $0 }
            )
        }
    }
}

/// 单击 / 长按 / 右键的 AppKit 触碰层。
/// SwiftUI 的 onLongPressGesture / contextMenu 在 ScrollView 里的行上实测收不到长按（onTap 正常），
/// 所以自己用 NSView 计时：按下 0.55s 未抬起 → 长按，抬起即取消。
struct MacPressHoldOverlay: NSViewRepresentable {
    var onTap: () -> Void
    var onLongPress: () -> Void
    var onSecondary: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> MacPressHoldView {
        let view = MacPressHoldView()
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onSecondary = onSecondary
        view.onHoverChange = onHoverChange
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacPressHoldView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ view: MacPressHoldView, context: Context) {
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onSecondary = onSecondary
        view.onHoverChange = onHoverChange
    }
}

final class MacPressHoldView: NSView {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var pending: DispatchWorkItem?
    private var didLongPress = false
    private var downPoint = NSPoint.zero

    override var isFlipped: Bool { true }
    private var hovering = false

    override func mouseDown(with event: NSEvent) {
        didLongPress = false
        downPoint = convert(event.locationInWindow, from: nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.didLongPress = true
            self.onLongPress?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - downPoint.x, point.y - downPoint.y) > 8 {
            pending?.cancel()
            pending = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        pending?.cancel()
        pending = nil
        if !didLongPress { onTap?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondary?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

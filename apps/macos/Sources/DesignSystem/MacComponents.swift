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
    var onEdit: () -> Void
    @ViewBuilder var menuContent: MenuContent

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                MacThumbnailView(thumbnailName: item.thumbnailName)
                    .aspectRatio(16 / 10, contentMode: .fit)

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
                .lineLimit(1)
            Text("\(item.fileSize.fileSizeText) · \(item.source == .editor ? "剪辑导出" : "本地导入")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(hovering ? 0.18 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("播放", action: onPlay)
            Button("剪辑", action: onEdit)
            menuContent
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

    /// 用 NSOpenPanel 选多个本地视频（⌘ / Shift 多选，一次导入多条素材）。
    @MainActor
    static func chooseVideoFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的视频（可多选）"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        return panel.runModal() == .OK ? panel.urls : []
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

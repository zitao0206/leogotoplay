import SwiftUI
import LeogotoPlayCore

// MARK: - 缩略图缓存

/// 缩略图体积小，直接读盘 + NSCache 缓存即可。
enum ImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func thumbnail(named name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let url = VideoFileStore.shared.thumbnailURL(named: name)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}

struct ThumbnailView: View {
    let thumbnailName: String?
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
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
            image = ImageCache.thumbnail(named: thumbnailName)
        }
    }
}

// MARK: - 视频卡片

struct VideoCard: View {
    let item: VideoItem
    var showsFolderName: Bool = false
    var folderName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 14)
                    .aspectRatio(16 / 10, contentMode: .fit)

                Text(item.duration.timecode)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Theme.accent, in: Circle())
                        .padding(6)
                }
            }

            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)

            if showsFolderName {
                Text(folderName ?? "未分类")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 视频列表行（V2.0.1）

/// 列表形式展示的视频行：缩略图 + 名称.mp4 + 大小 / 添加日期 / 时长。
struct VideoListRow: View {
    let item: VideoItem
    var showsFolderName: Bool = false
    var folderName: String? = nil

    private var metaText: String {
        "\(item.fileSize.fileSizeText) · \(item.createdAt.dateText) · \(item.duration.timecode)"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(thumbnailName: item.thumbnailName, cornerRadius: 10)
                    .frame(width: 92, height: 58)
                    .clipped()

                Text(item.duration.timecode)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayNameWithExtension)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(metaText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsFolderName {
                    Text(folderName ?? "未分类")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 文件夹列表行（V2.0.1）

/// 列表形式的文件夹行：图标 + 名称 + 视频数量。
struct FolderListRow: View {
    let folder: VideoFolder
    let videoCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(videoCount) 个视频")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 文件夹卡片

struct FolderCard: View {
    let folder: VideoFolder
    let videoCount: Int
    let coverThumbnails: [String?]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.accent)
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                if coverThumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(Image(systemName: "film.stack").foregroundStyle(.secondary))
                } else {
                    ForEach(Array(coverThumbnails.prefix(3).enumerated()), id: \.offset) { _, name in
                        ThumbnailView(thumbnailName: name, cornerRadius: 8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .clipped()
                    }
                }
            }

            Text("\(videoCount) 个视频")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.85))
                .padding(.bottom, 2)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    var fillsWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentGradient)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - 小组件

struct StatItem: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Toast

struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            withAnimation(.easeOut(duration: 0.2)) { self.message = nil }
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

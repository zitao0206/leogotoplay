import SwiftUI
import LeogotoPlayCore

/// 侧栏分区：对应 iOS 的三个 Tab（Cut / Library / Mine），桌面端以侧栏 + 主区域呈现。
/// V3.0.0：原 List 统一改名 Library（与 iOS 对齐），侧栏底部不再显示登录状态。
enum MacSection: String, CaseIterable, Identifiable {
    // V2.8.12：首页分区顺序改为 Library（素材库）→ Cut（剪辑台）→ Mine
    case library
    case cut
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .library: return "Library"
        case .mine: return "Mine"
        }
    }

    var subtitle: String {
        switch self {
        case .cut: return "剪辑台"
        case .library: return "素材库"
        case .mine: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .cut: return "scissors"
        case .library: return "square.grid.2x2"
        case .mine: return "person.crop.circle"
        }
    }
}

struct MacRootView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var selection: MacSection? = MacRootView.initialSection()

    /// 默认进「素材库」；Debug 下可用启动参数 `-startSection cut` 直达某个分区，方便截图与调试。
    private static func initialSection() -> MacSection {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let section = MacSection(rawValue: raw) {
            return section
        }
        #endif
        return .library
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(MacSection.allCases) { section in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                Text(section.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(MacTheme.accent)
                        }
                        .tag(section)
                    }
                } header: {
                    Text("LEOGOTOPLAY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: MacTheme.sidebarWidth, max: 260)
            .safeAreaInset(edge: .bottom) {
                // V1.0：这里原来显示账号名（登录状态），已去掉，只留素材库统计。
                Text("\(library.videos.count) 个视频 · \(library.totalSize.fileSizeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .library {
        case .cut:
            MacCutView()
        case .library:
            MacLibraryView()
        case .mine:
            MacMineView()
        }
    }
}

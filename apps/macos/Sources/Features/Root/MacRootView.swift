import SwiftUI
import LeogotoPlayCore

/// 侧栏分区：对应 iOS 的三个 Tab（Cut / Library / Mine），桌面端以侧栏 + 主区域呈现。
/// V3.0.0：原 List 统一改名 Library（与 iOS 对齐），侧栏底部不再显示登录状态。
enum MacSection: String, CaseIterable, Identifiable {
    // V2.8.12：首页分区顺序改为 Library（视频库）→ Cut（剪辑台）→ Mine
    case library
    case cut
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .library: return "Library"
        case .mine: return "Me"
        }
    }

    var subtitle: String {
        switch self {
        case .cut: return T("剪辑台")
        case .library: return T("视频库")
        case .mine: return MacLang.current == .zh ? "我的" : "Account"
        }
    }

    var isVisible: Bool {
        switch self {
        case .library: return UserDefaults.standard.object(forKey: MacTabPrefs.showListKey) as? Bool ?? true
        case .cut: return UserDefaults.standard.object(forKey: MacTabPrefs.showCutKey) as? Bool ?? true
        case .mine: return true
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

/// V4.0：功能选择偏好（Library / Cut 显隐），存 UserDefaults，Mine 设置页与侧栏共用。
enum MacTabPrefs {
    static let showListKey = "tab.list.visible"
    static let showCutKey = "tab.cut.visible"
}

struct MacRootView: View {
    @EnvironmentObject private var library: LibraryStore
    // V4.3：语言一变，侧栏与详情一起换文案（详情靠 .id 重建，侧栏随 body 重算）
    @ObservedObject private var language = MacLanguageStore.shared

    /// V4.3：当前分区持久化，语言切换重建根视图后仍停在原来的分区
    @AppStorage("tab.selected") private var selectedRaw: String = MacRootView.initialSection().rawValue

    @AppStorage(MacTabPrefs.showListKey) private var showList = true
    @AppStorage(MacTabPrefs.showCutKey) private var showCut = true

    init() {
        #if DEBUG
        // 启动参数 -startSection cut|library|mine：截图/调试直达分区
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           MacSection(rawValue: raw) != nil {
            UserDefaults.standard.set(raw, forKey: "tab.selected")
        }
        #endif
    }

    /// 默认进「视频库」；Debug 下可用启动参数 `-startSection cut` 直达某个分区，方便截图与调试。
    private static func initialSection() -> MacSection {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let section = MacSection(rawValue: raw), section.isVisible {
            return section
        }
        #endif
        return .library
    }

    private var selection: MacSection {
        guard let section = MacSection(rawValue: selectedRaw), section.isVisible else {
            return visibleSections.first ?? .mine
        }
        return section
    }

    private var selectionBinding: Binding<MacSection?> {
        Binding(
            get: { MacSection(rawValue: selectedRaw) ?? .library },
            set: { selectedRaw = ($0 ?? .library).rawValue }
        )
    }

    /// 侧栏实际展示的分区：Mine 恒显，Library / Cut 受「功能选择」控制
    private var visibleSections: [MacSection] {
        MacSection.allCases.filter { $0.isVisible }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                Section {
                    ForEach(visibleSections) { section in
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
            // 侧栏原来透的是系统 sidebar 材质（灰），这里换成与主区一致的纯黑画布
            .scrollContentBackground(.hidden)
            .background(MacTheme.canvas)
            .safeAreaInset(edge: .bottom) {
                // V1.0：这里原来显示账号名（登录状态），已去掉，只留视频库统计。
                Text(T("{1} 个视频 · {2}", library.videos.count, library.totalSize.fileSizeText))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MacTheme.canvas)
            }
        } detail: {
            detail
                .id(language.current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reconcileSelection() }
        .onChange(of: showList) { _ in reconcileSelection() }
        .onChange(of: showCut) { _ in reconcileSelection() }
    }

    /// 当前分区被用户在「功能选择」里关掉时，自动跳到还留着的那一个
    private func reconcileSelection() {
        if let current = MacSection(rawValue: selectedRaw), current.isVisible { return }
        selectedRaw = (visibleSections.first ?? .mine).rawValue
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .cut:
            MacCutView()
        case .library:
            MacLibraryView()
        case .mine:
            MacMineView()
        }
    }
}

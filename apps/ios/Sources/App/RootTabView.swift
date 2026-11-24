import SwiftUI
import LeogotoPlayCore

/// 首页容器：List / Cut / Mine 三个 Tab（V2.0.1 起 List 在前），由 AppConfig 驱动。
/// V4.0：List / Cut 可以在 Mine → 设置里单独关掉。系统 TabView 在子页数量变化后会留下空白页，
/// 用 `.id` 强制重建又会把正在显示的设置弹窗一起关掉，所以改成自绘底部 Tab 栏：
/// 三个页面常驻、只切换显示与命中，切 Tab 也不会丢各自页面的状态。
struct RootTabView: View {
    private let config = AppConfig.current
    @State private var selection: AppConfig.Tab = RootTabView.initialTab()

    // V4.0：List / Cut 的显隐由 Mine → 设置页控制，两个 key 存本地
    @AppStorage(TabPrefs.showListKey) private var showList = true
    @AppStorage(TabPrefs.showCutKey) private var showCut = true

    /// 默认落在配置里的第一个 Tab；Debug 下可用 `-startTab list` 启动参数直达某个 Tab，方便调试。
    private static func initialTab() -> AppConfig.Tab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "startTab"),
           let tab = AppConfig.Tab(rawValue: raw),
           AppConfig.current.visibleTabs.contains(tab) {
            return tab
        }
        #endif
        return AppConfig.current.visibleTabs.first ?? .mine
    }

    /// 当前实际展示的 Tab（设置页关掉的那个会被过滤掉，Mine 恒定保留）
    private var tabs: [AppConfig.Tab] {
        config.tabs.filter { tab in
            switch tab {
            case .list: return showList
            case .cut: return showCut
            case .mine: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 三个页面都常驻，切 Tab 不丢各自的导航栈 / 滚动位置
            ZStack {
                ForEach(AppConfig.Tab.allCases) { tab in
                    tabContent(tab)
                        .opacity(tab == selection ? 1 : 0)
                        .allowsHitTesting(tab == selection)
                        .accessibilityHidden(tab != selection)
                        .zIndex(tab == selection ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
        // 设置里关掉当前所在 Tab 时，自动落到第一个可见 Tab
        .onChange(of: showList) { _ in ensureSelection() }
        .onChange(of: showCut) { _ in ensureSelection() }
        // 深链：leogotoplay://cut / leogotoplay://list / leogotoplay://mine
        .onOpenURL { url in
            guard url.scheme == "leogotoplay",
                  let host = url.host,
                  let tab = AppConfig.Tab(rawValue: host),
                  tabs.contains(tab) else { return }
            selection = tab
        }
    }

    // MARK: - 自绘底部 Tab 栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    guard tab != selection else { return }
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 26)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tab == selection ? Theme.accent : Color(uiColor: .secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selection ? [.isSelected] : [])
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func ensureSelection() {
        guard !tabs.contains(selection) else { return }
        selection = tabs.first ?? .mine
    }

    @ViewBuilder
    private func tabContent(_ tab: AppConfig.Tab) -> some View {
        switch tab {
        case .cut:
            NavigationStack { CutHomeView() }
        case .list:
            NavigationStack { LibraryView() }
        case .mine:
            NavigationStack { MineView() }
        }
    }
}

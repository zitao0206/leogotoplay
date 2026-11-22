import SwiftUI
import LeogotoPlayCore

/// 首页容器：Cut / List / Mine 三个 Tab，由 AppConfig 驱动。
struct RootTabView: View {
    private let config = AppConfig.current
    @State private var selection: AppConfig.Tab = RootTabView.initialTab()

    /// 默认落在配置里的第一个 Tab；Debug 下可用 `-startTab list` 启动参数直达某个 Tab，方便调试。
    private static func initialTab() -> AppConfig.Tab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "startTab"),
           let tab = AppConfig.Tab(rawValue: raw),
           AppConfig.current.tabs.contains(tab) {
            return tab
        }
        #endif
        return AppConfig.current.tabs.first ?? .cut
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(config.tabs) { tab in
                tabContent(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
        // 深链：leogotoplay://cut / leogotoplay://list / leogotoplay://mine
        .onOpenURL { url in
            guard url.scheme == "leogotoplay",
                  let host = url.host,
                  let tab = AppConfig.Tab(rawValue: host),
                  config.tabs.contains(tab) else { return }
            selection = tab
        }
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

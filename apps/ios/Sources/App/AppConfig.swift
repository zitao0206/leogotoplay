import SwiftUI
import LeogotoPlayCore

/// 全局可配置项：首页 Tab 结构、功能开关。
/// 想调整 Tab 数量 / 顺序 / 显隐，只改 `AppConfig.current.tabs` 即可。
struct AppConfig {

    enum Tab: String, CaseIterable, Identifiable {
        case cut
        case list
        case mine

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cut: return "Cut"
            case .list: return "Library"
            case .mine: return "Mine"
            }
        }

        var subtitle: String {
            switch self {
            case .cut: return "剪辑"
            case .list: return "视频库"
            case .mine: return "我的"
            }
        }

        var systemImage: String {
            switch self {
            case .cut: return "scissors"
            case .list: return "square.grid.2x2.fill"
            case .mine: return "person.crop.circle.fill"
            }
        }
    }

    /// 首页展示的 Tab，顺序即展示顺序。（V2.0.1：List 提到 Cut 前面）
    var tabs: [Tab] = [.list, .cut, .mine]

    /// 是否允许从系统相册导入视频进行剪辑。
    var allowsPhotoImport = true

    /// 是否允许从「文件」App 导入视频。
    var allowsFileImport = true

    /// 是否允许未登录用户使用剪辑功能。
    var allowsAnonymousEditing = true

    /// 实际展示的 Tab：按 `tabs` 顺序过滤掉用户在设置里关掉的那一个。
    /// Mine 恒定显示，List / Cut 由 `TabPrefs` 控制。
    var visibleTabs: [Tab] {
        tabs.filter { TabPrefs.isVisible($0) }
    }

    static let current = AppConfig()
}

/// V4.0：首页 Tab 显隐偏好，存本地 UserDefaults，设置页与 Tab 栏共享同一组 key。
enum TabPrefs {
    static let showListKey = "tab.list.visible"
    static let showCutKey = "tab.cut.visible"

    static func isVisible(_ tab: AppConfig.Tab) -> Bool {
        switch tab {
        case .list: return UserDefaults.standard.object(forKey: showListKey) as? Bool ?? true
        case .cut: return UserDefaults.standard.object(forKey: showCutKey) as? Bool ?? true
        case .mine: return true
        }
    }
}

import AppKit
import SwiftUI
import LeogotoPlayCore

@main
struct LeogotoPlayMacApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var auth = AuthStore()

    init() {
        // V2.0：整个 App 走深色外观（黑底 + 暖红点缀），和 Cut 页的黑红主视觉一致
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(library)
                .environmentObject(auth)
                .tint(MacTheme.accent)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入视频…") {
                    NotificationCenter.default.post(name: .macImportVideo, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let macImportVideo = Notification.Name("leogotoplay.mac.importVideo")
}

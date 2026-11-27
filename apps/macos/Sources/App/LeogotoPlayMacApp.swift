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
                .background(MacWindowChromeConfigurator())
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

/// 顶部标题栏原来透出系统窗口材质（灰），这里把窗口底色刷成纯黑、标题栏透明，
/// 侧栏/标题栏与页面画布连成一片黑。
private struct MacWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = NSColor(red: 0.059, green: 0.059, blue: 0.067, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
    }
}

extension Notification.Name {
    static let macImportVideo = Notification.Name("leogotoplay.mac.importVideo")
}

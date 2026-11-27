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

        // V4.1.0：退出 App 时兜底清掉 Cut 各功能留在临时目录的成品（窗口没关就直接退出的情况）
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            let fm = FileManager.default
            let temp = fm.temporaryDirectory
            guard let items = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) else { return }
            for url in items {
                let name = url.lastPathComponent
                guard name.hasPrefix("mac-split-") || name.hasPrefix("mac-face-mask") else { continue }
                try? fm.removeItem(at: url)
            }
        }
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
                Button(T("导入视频…")) {
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

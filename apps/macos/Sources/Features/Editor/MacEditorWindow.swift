import AppKit
import SwiftUI
import LeogotoPlayCore

extension Notification.Name {
    /// 剪辑窗口关闭：Cut 首页据此刷新「最近编辑」的草稿角标
    static let macEditorWindowClosed = Notification.Name("leogotoplay.mac.editorWindowClosed")
}

/// 剪辑页独立开窗（V2.3）：从 Cut 首页或素材库进剪辑时都新开一个窗口，不再挤在主窗口里。
/// 同一条素材已经有窗口在剪时，直接把那个窗口提到前面（草稿现场不会丢）。
@MainActor
final class MacEditorWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacEditorWindowManager()

    private struct Entry {
        let window: NSWindow
        let videoID: UUID?
    }

    private var entries: [Entry] = []

    func open(source: MacEditorSource?, library: LibraryStore) {
        if let videoID = source?.libraryVideoID,
           let existing = entries.first(where: { $0.videoID == videoID }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = source.map { "剪辑 · \($0.title)" } ?? "新建剪辑"
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 1040, height: 660)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let root = MacEditorView(initialSource: source) { [weak window] in
            window?.close()
        }
        .environmentObject(library)
        .tint(MacTheme.accent)

        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        entries.append(Entry(window: window, videoID: source?.libraryVideoID))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        entries.removeAll { $0.window === window }
        NotificationCenter.default.post(name: .macEditorWindowClosed, object: nil)
    }
}

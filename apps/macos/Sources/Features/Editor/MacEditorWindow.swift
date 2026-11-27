import AppKit
import SwiftUI
import LeogotoPlayCore

extension Notification.Name {
    /// 剪辑窗口关闭：Cut 首页据此刷新「最近编辑」的草稿角标
    static let macEditorWindowClosed = Notification.Name("leogotoplay.mac.editorWindowClosed")
}

/// 剪辑页独立开窗（V2.3）：从 Cut 首页或素材库进剪辑时都新开一个窗口，不再挤在主窗口里。
/// V2.8.6 起窗口的单位是「项目」（MacProjectRecord）：同一个项目已有窗口就把它提到前面。
@MainActor
final class MacEditorWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacEditorWindowManager()

    private struct Entry {
        let window: NSWindow
        let projectID: UUID
    }

    private var entries: [Entry] = []


    /// 首页 / 素材库入口：source 为 nil 就是全新空白项目；带素材库视频时复用它已有的项目。
    func open(source: MacEditorSource?, library: LibraryStore) {
        let project: MacProjectRecord
        if let source {
            if let existing = MacProjectStore.project(referencingFileAt: source.url.path) {
                project = existing
            } else {
                project = MacProjectStore.newProject(
                    libraryFile: source.url,
                    title: source.title,
                    videoID: source.libraryVideoID ?? UUID()
                )
            }
        } else {
            project = MacProjectStore.newBlankProject()
        }
        present(project, library: library)
    }

    /// 最近编辑入口：按项目 id 还原现场
    func open(projectID: UUID, library: LibraryStore) {
        guard let project = MacProjectStore.project(id: projectID) else { return }
        present(project, library: library)
    }

    private func present(_ project: MacProjectRecord, library: LibraryStore) {
        if let existing = entries.first(where: { $0.projectID == project.id }) {
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
        // V2.8.2：剪辑窗口不参与系统的「重新打开窗口」恢复，避免下次启动被系统还原出上一次的项目
        window.isRestorable = false
        // V2.9.6：标题栏不再显示项目名（项目名只在编辑页左上角显示）
        window.title = ""
        window.titleVisibility = .hidden
        window.subtitle = "LeogotoPlay"
        window.minSize = NSSize(width: 1040, height: 660)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        window.center()
        window.delegate = self

        let root = MacEditorView(project: project)
            .environmentObject(library)
            .tint(MacTheme.accent)

        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        entries.append(Entry(window: window, projectID: project.id))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        entries.removeAll { $0.window === window }
        NotificationCenter.default.post(name: .macEditorWindowClosed, object: nil)
    }
}

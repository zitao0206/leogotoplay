import SwiftUI
import LeogotoPlayCore

@main
struct LeogotoPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(library)
                .environmentObject(auth)
                .tint(Theme.accent)
        }
    }
}

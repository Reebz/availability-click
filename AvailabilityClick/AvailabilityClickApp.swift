import SwiftUI

@main
struct CalendarClickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No scenes — this is a menu bar-only app.
        // Settings window is managed manually via NSWindow + NSHostingController
        // in StatusItemController to avoid the SettingsLink requirement.
        Settings {
            EmptyView()
        }
    }
}

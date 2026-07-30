import SwiftUI

@main
struct CoreEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // CoreEQ is a menu bar app (LSUIElement); the main window is managed
        // by AppDelegate so it can be opened from the status item menu.
        Settings {
            EmptyView()
        }
    }
}

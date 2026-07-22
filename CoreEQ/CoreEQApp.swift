import AppKit
import Combine
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var profileManager = ProfileManager(settings: settings)
    private lazy var audioEngine = AudioEngine(settings: settings)
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            profileManager: profileManager,
            audioEngine: audioEngine,
            openMainWindow: { [weak self] in self?.showMainWindow() }
        )

        let audioEngine = self.audioEngine
        profileManager.$currentBands
            .sink { audioEngine.apply(bands: $0) }
            .store(in: &cancellables)

        audioEngine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioEngine.stop()
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView(profileManager: profileManager, audioEngine: audioEngine)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "CoreEQ"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

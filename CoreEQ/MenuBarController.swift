import AppKit
import Foundation

/// Owns the NSStatusItem. The menu is rebuilt each time it opens
/// (`menuNeedsUpdate`), so it always reflects the current state without any
/// change observation plumbing.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let profileManager: ProfileManager
    private let audioEngine: AudioEngine
    private let openMainWindow: () -> Void

    init(profileManager: ProfileManager, audioEngine: AudioEngine, openMainWindow: @escaping () -> Void) {
        self.profileManager = profileManager
        self.audioEngine = audioEngine
        self.openMainWindow = openMainWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "CoreEQ")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "CoreEQ"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for profile in profileManager.listProfiles() {
            let item = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.name
            item.state = profile.name == profileManager.activeProfileName ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let bypassItem = NSMenuItem(title: "Enable Equalizer", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        bypassItem.target = self
        bypassItem.state = audioEngine.isEnabled ? .on : .off
        menu.addItem(bypassItem)

        if case .failed(let message) = audioEngine.status {
            let statusItem = NSMenuItem(title: "⚠️ \(message)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open CoreEQ…", action: #selector(openWindow(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit CoreEQ", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        profileManager.setActiveProfile(name: name)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        audioEngine.isEnabled.toggle()
    }

    @objc private func openWindow(_ sender: NSMenuItem) {
        openMainWindow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

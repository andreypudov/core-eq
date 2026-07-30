import AppKit
import CoreAudio
import Foundation

/// Owns the NSStatusItem and its menu. The menu is a real `NSMenu` assigned to
/// the status item, so it behaves exactly like the system Wi‑Fi / Sound menus:
/// no popover arrow, system menu font, and automatic dismissal when another menu
/// bar menu opens. Interactive pieces the menu can't express natively — the
/// header on/off switch, the live response graph, and the tone sliders — are
/// custom views (`QuickEQMenuViews`) embedded via `NSMenuItem.view`. Preset and
/// output selection use native submenus.
///
/// The menu is rebuilt each time it opens (`menuNeedsUpdate`), so it always
/// reflects the current state without any change-observation plumbing.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let profileManager: ProfileManager
    private let audioEngine: AudioEngine
    private let openMainWindow: () -> Void
    private let openSettings: () -> Void

    /// Kept between rebuilds so tone-slider changes can redraw the graph in
    /// place while the menu stays open.
    private weak var quickEQBody: QuickEQBodyView?

    init(
        profileManager: ProfileManager,
        audioEngine: AudioEngine,
        openMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.profileManager = profileManager
        self.audioEngine = audioEngine
        self.openMainWindow = openMainWindow
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIconTemplate")
                ?? NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "CoreEQ")
            image?.isTemplate = true
            image?.accessibilityDescription = "CoreEQ"
            button.image = image
            button.toolTip = "CoreEQ"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(headerItem())
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Preset"))
        menu.addItem(presetItem())
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Quick EQ"))
        menu.addItem(quickEQItem())
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Output"))
        menu.addItem(outputItem())
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Equalizer…", action: #selector(openWindow(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CoreEQ", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Items

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuHeaderView(isOn: audioEngine.isEnabled) { [weak self] isOn in
            self?.audioEngine.isEnabled = isOn
            self?.quickEQBody?.alphaValue = isOn ? 1.0 : 0.45
        }
        return item
    }

    private func presetItem() -> NSMenuItem {
        let item = NSMenuItem(title: profileManager.activeProfileName, action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for profile in profileManager.listProfiles() {
            let profileItem = NSMenuItem(title: profile.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            profileItem.target = self
            profileItem.representedObject = profile.name
            profileItem.state = profile.name == profileManager.activeProfileName ? .on : .off
            submenu.addItem(profileItem)
        }
        item.submenu = submenu
        return item
    }

    private func quickEQItem() -> NSMenuItem {
        let body = QuickEQBodyView(
            bands: profileManager.currentBands,
            tone: profileManager.tone,
            sampleRate: audioEngine.sampleRate
        ) { [weak self] axis, value in
            self?.applyTone(axis: axis, value: value)
        }
        body.alphaValue = audioEngine.isEnabled ? 1.0 : 0.45
        quickEQBody = body

        let item = NSMenuItem()
        item.view = body
        return item
    }

    private func outputItem() -> NSMenuItem {
        let currentID = AudioDevices.defaultOutputDeviceID()
        let currentName = currentID.flatMap { AudioDevices.name(of: $0) } ?? "Unknown"
        let item = NSMenuItem(title: currentName, action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let devices = AudioDevices.outputDevices()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No output devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for device in devices {
            let deviceItem = NSMenuItem(title: device.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.representedObject = device.id
            // Selection is shown Control-Center style — the icon badge fills
            // with the accent colour — so no checkmark state is set.
            deviceItem.image = Self.deviceIcon(device.symbolName, selected: device.id == currentID)
            submenu.addItem(deviceItem)
        }
        item.submenu = submenu
        return item
    }

    /// Renders a device SF Symbol inside a circular badge, Control-Center
    /// style: a translucent circle behind the glyph, or an accent-filled circle
    /// with a white glyph for the selected device. Drawn into a real bitmap
    /// because NSMenu ignores symbol configurations and lays out symbol images
    /// at its own standard size. The drawing handler runs at display time, so
    /// the dynamic colours resolve correctly for Light / Dark mode.
    private static func deviceIcon(_ symbolName: String, selected: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let side: CGFloat = 28
        let glyphInset: CGFloat = 4
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(ovalIn: rect).fill()

            let glyphColor: NSColor = selected ? .white : .labelColor
            let tinted = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [glyphColor])
            ) ?? symbol

            let box = rect.insetBy(dx: glyphInset, dy: glyphInset)
            let symbolSize = tinted.size
            guard symbolSize.width > 0, symbolSize.height > 0 else { return true }
            let scale = min(box.width / symbolSize.width, box.height / symbolSize.height)
            let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
            let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
            tinted.draw(in: NSRect(origin: origin, size: drawSize))
            return true
        }
    }

    // MARK: - Actions

    private func applyTone(axis: QuickEQBodyView.Axis, value: Double) {
        switch axis {
        case .bass: profileManager.setTone(bass: value)
        case .mid: profileManager.setTone(mid: value)
        case .treble: profileManager.setTone(treble: value)
        }
        quickEQBody?.refreshGraph(bands: profileManager.currentBands)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        profileManager.setActiveProfile(name: name)
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioDevices.setDefaultOutputDevice(id)
    }

    @objc private func openWindow(_ sender: NSMenuItem) {
        openMainWindow()
    }

    @objc private func openSettingsItem(_ sender: NSMenuItem) {
        openSettings()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

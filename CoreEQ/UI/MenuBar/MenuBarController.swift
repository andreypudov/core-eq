import AppKit
import CoreAudio
import Foundation

/// Owns the NSStatusItem and its menu. The menu is a real `NSMenu` assigned to
/// the status item, so it behaves exactly like the system Wi‑Fi / Sound menus:
/// no popover arrow, system menu font, and automatic dismissal when another menu
/// bar menu opens. Interactive pieces the menu can't express natively — the
/// header on/off switch, the live response graph, the tone sliders, and the two
/// choosers — are custom views (`QuickEQMenuViews`, `MenuListViews`) embedded via
/// `NSMenuItem.view`.
///
/// Preset and output selection follow the Wi‑Fi menu: the row names the current
/// value and carries a chevron, and clicking it opens the options *in this
/// menu*, in the row's own place, scrolling once the list outgrows its cap. Only
/// one section is open at a time. Expanding swaps the row for a single list item
/// on the live menu (`expand(_:in:)`) instead of rebuilding it, so the menu
/// never flickers and never closes mid-choice.
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

    /// The two rows that can unfold a list under themselves.
    private enum ListSection {
        case preset, output
    }

    /// State of the open menu: which section has its list showing, the value
    /// rows that list displaced, and the list item itself. All of it is torn
    /// down when the menu closes.
    private var expandedSection: ListSection?
    private var sectionItems: [ListSection: NSMenuItem] = [:]
    private var listItem: NSMenuItem?

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
        expandedSection = nil
        listItem = nil
        sectionItems.removeAll()

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

    /// Every open starts with both sections folded, so nothing is left holding
    /// on to rows from a menu that no longer exists.
    func menuDidClose(_ menu: NSMenu) {
        expandedSection = nil
        listItem = nil
        sectionItems.removeAll()
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

    /// The active preset, with a chevron that opens the full list in its place.
    private func presetItem() -> NSMenuItem {
        disclosureItem(
            for: .preset,
            title: profileManager.activeProfileName,
            height: MenuListMetrics.rowHeight,
            canExpand: profileManager.listProfiles().count > 1
        )
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

    /// The device the sound is going to. Clicking it puts every device in its
    /// place — unless the machine only has the one, when there is nothing to
    /// choose between: the row then states where the sound goes, without a
    /// chevron.
    private func outputItem() -> NSMenuItem {
        let currentID = AudioDevices.defaultOutputDeviceID()
        let devices = AudioDevices.outputDevices()
        let current = devices.first { $0.id == currentID }

        guard let current else {
            // No usable output at all: no name to state, and nothing to open.
            let item = NSMenuItem(title: "No output devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        return disclosureItem(
            for: .output,
            title: current.name,
            image: Self.deviceIcon(current.symbolName, selected: true),
            gutter: MenuListMetrics.badgeGutter,
            height: MenuListMetrics.deviceRowHeight,
            canExpand: devices.count > 1
        )
    }

    /// Builds one of the two value rows: a `MenuRowView` in a view-based item,
    /// registered so `expand(_:in:)` knows which item its list replaces.
    private func disclosureItem(
        for section: ListSection,
        title: String,
        image: NSImage? = nil,
        gutter: CGFloat = 0,
        height: CGFloat,
        canExpand: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let row = MenuRowView(
            title: title,
            image: image,
            gutter: gutter,
            height: height,
            accessory: canExpand ? .disclosure : .none
        ) { [weak self] in
            guard canExpand else { return }
            self?.expand(section)
        }
        item.view = row
        sectionItems[section] = item
        return item
    }

    // MARK: - Disclosure

    /// Puts the section's options where its row was. Any other open section
    /// folds back to its row first, so the menu only ever shows one list.
    private func expand(_ section: ListSection) {
        guard let menu = statusItem.menu, expandedSection != section else { return }
        collapse(in: menu)
        expand(section, in: menu)
    }

    /// Restores the open section's row in place of its list.
    private func collapse(in menu: NSMenu) {
        defer {
            listItem = nil
            expandedSection = nil
        }
        guard let expandedSection, let listItem, let rowItem = sectionItems[expandedSection] else { return }
        let index = menu.index(of: listItem)
        guard index >= 0 else { return }
        menu.removeItem(at: index)
        menu.insertItem(rowItem, at: index)
    }

    /// Swaps the section's row for its options. The menu is open while this
    /// runs: AppKit re-lays it out around the new item, which is what makes the
    /// list appear in place rather than in a submenu.
    private func expand(_ section: ListSection, in menu: NSMenu) {
        guard let rowItem = sectionItems[section] else { return }
        let index = menu.index(of: rowItem)
        guard index >= 0 else { return }

        let rowHeight: CGFloat
        let rows: [MenuRowView]
        let activeIndex: Int
        switch section {
        case .preset:
            rowHeight = MenuListMetrics.rowHeight
            (rows, activeIndex) = presetRows()
        case .output:
            rowHeight = MenuListMetrics.deviceRowHeight
            (rows, activeIndex) = outputRows()
        }
        guard !rows.isEmpty else { return }

        let list = MenuListView(rows: rows, rowHeight: rowHeight)
        let item = NSMenuItem()
        item.view = list
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
        list.revealRow(at: activeIndex)

        listItem = item
        expandedSection = section
    }

    /// Every preset, plain. Nothing marks the active one: the row you clicked to
    /// get here was its name, and picking any of these closes the menu.
    private func presetRows() -> ([MenuRowView], Int) {
        let profiles = profileManager.listProfiles()
        let active = profileManager.activeProfileName
        let rows = profiles.map { profile in
            MenuRowView(title: profile.name, height: MenuListMetrics.rowHeight) { [weak self] in
                self?.profileManager.setActiveProfile(name: profile.name)
                self?.dismissMenu()
            }
        }
        return (rows, profiles.firstIndex { $0.name == active } ?? 0)
    }

    /// Every output device. The one in use is the one with the accent-filled
    /// badge — the same mark the collapsed row carries — so the list needs no
    /// checkmark of its own.
    private func outputRows() -> ([MenuRowView], Int) {
        let devices = AudioDevices.outputDevices()
        let currentID = AudioDevices.defaultOutputDeviceID()
        let rows = devices.map { device in
            MenuRowView(
                title: device.name,
                image: Self.deviceIcon(device.symbolName, selected: device.id == currentID),
                gutter: MenuListMetrics.badgeGutter,
                height: MenuListMetrics.deviceRowHeight
            ) { [weak self] in
                AudioDevices.setDefaultOutputDevice(device.id)
                self?.dismissMenu()
            }
        }
        return (rows, devices.firstIndex { $0.id == currentID } ?? 0)
    }

    /// Picking an option closes the menu, as picking one in a submenu did.
    private func dismissMenu() {
        statusItem.menu?.cancelTracking()
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

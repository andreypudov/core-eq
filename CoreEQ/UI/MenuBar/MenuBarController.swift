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
/// value and carries a `>`, and clicking it turns that into a `v` and unfolds
/// the remaining options *in this menu*, right below the row, scrolling once the
/// list outgrows its cap. The row stays put, so clicking it again folds the list
/// away. Only one section is open at a time. Expanding inserts a single list
/// item into the live menu (`expand(_:in:)`) instead of rebuilding it, so the
/// menu never flickers and never closes mid-choice.
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
    /// rows that own the chevrons, and the list item itself. All of it is torn
    /// down when the menu closes.
    private var expandedSection: ListSection?
    private var disclosureRows: [ListSection: MenuRowView] = [:]
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
        disclosureRows.removeAll()
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
        disclosureRows.removeAll()
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

    /// The active preset, with a chevron that unfolds the others below it.
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
            filters: profileManager.currentFilters,
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

    /// The device the sound is going to. Clicking it unfolds the others below
    /// it — unless the machine only has the one, when there is nothing to choose
    /// between: the row then states where the sound goes, without a chevron.
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
    /// registered so `expand(_:in:)` knows where to put its list and which
    /// chevron to turn.
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
            accessory: canExpand ? .disclosure(expanded: false) : .none
        ) { [weak self] in
            guard canExpand else { return }
            self?.toggle(section)
        }
        item.view = row
        disclosureRows[section] = row
        sectionItems[section] = item
        return item
    }

    // MARK: - Disclosure

    /// Opens the section under its row, folding away whichever section was open
    /// — or folds this one away if it was the one open. That second case is what
    /// makes the value row a way back out: it is still there above the list,
    /// still showing the current choice, and clicking it closes the list again.
    private func toggle(_ section: ListSection) {
        guard let menu = statusItem.menu else { return }
        let wasOpen = expandedSection == section
        collapse(in: menu)
        guard !wasOpen else { return }
        expand(section, in: menu)
    }

    /// Removes the open list and turns its chevron back to `>`.
    private func collapse(in menu: NSMenu) {
        if let listItem, menu.index(of: listItem) >= 0 {
            menu.removeItem(listItem)
        }
        listItem = nil
        if let expandedSection {
            disclosureRows[expandedSection]?.setExpanded(false)
        }
        expandedSection = nil
    }

    /// Inserts the section's other options directly under its row. The menu is
    /// open while this runs: AppKit re-lays it out around the new item, which is
    /// what makes the list appear in place rather than in a submenu.
    private func expand(_ section: ListSection, in menu: NSMenu) {
        guard let rowItem = sectionItems[section] else { return }
        let index = menu.index(of: rowItem)
        guard index >= 0 else { return }

        let rowHeight: CGFloat
        let rows: [MenuRowView]
        switch section {
        case .preset:
            rowHeight = MenuListMetrics.rowHeight
            rows = presetRows()
        case .output:
            rowHeight = MenuListMetrics.deviceRowHeight
            rows = outputRows()
        }
        guard !rows.isEmpty else { return }

        let item = NSMenuItem()
        item.view = MenuListView(rows: rows, rowHeight: rowHeight)
        menu.insertItem(item, at: index + 1)

        listItem = item
        expandedSection = section
        disclosureRows[section]?.setExpanded(true)
    }

    /// Every preset except the active one — that one is the row above, and
    /// repeating it here would only offer a choice that changes nothing.
    private func presetRows() -> [MenuRowView] {
        let active = profileManager.activeProfileName
        return profileManager.listProfiles()
            .filter { $0.name != active }
            .map { profile in
                MenuRowView(title: profile.name, height: MenuListMetrics.rowHeight) { [weak self] in
                    self?.profileManager.setActiveProfile(name: profile.name)
                    self?.dismissMenu()
                }
            }
    }

    /// Every output device except the one in use. Its accent-filled badge stays
    /// on the row above, so the list is all plain badges: what else there is.
    private func outputRows() -> [MenuRowView] {
        let currentID = AudioDevices.defaultOutputDeviceID()
        return AudioDevices.outputDevices()
            .filter { $0.id != currentID }
            .map { device in
                MenuRowView(
                    title: device.name,
                    image: Self.deviceIcon(device.symbolName, selected: false),
                    gutter: MenuListMetrics.badgeGutter,
                    height: MenuListMetrics.deviceRowHeight
                ) { [weak self] in
                    AudioDevices.setDefaultOutputDevice(device.id)
                    self?.dismissMenu()
                }
            }
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
        quickEQBody?.refreshGraph(filters: profileManager.currentFilters)
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

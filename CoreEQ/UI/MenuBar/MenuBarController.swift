import AppKit
import Combine
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
    /// The same device list the window's picker reads, rather than a second
    /// enumeration of Core Audio. Two lists could disagree — and the one built
    /// on menu open cost a full walk of every device's name, transport, data
    /// source, and stream configuration, twice, every time the menu was opened.
    private let outputs: AudioDeviceList
    private let openMainWindow: () -> Void

    /// Installed here because opening the Settings scene needs a SwiftUI view
    /// inside a live window, and the status item's button is the one that exists
    /// for the app's whole life. Everything else — the window's gear, the
    /// sidebar's app mark — reaches the same shared opener. See `SettingsOpener`.
    private let settingsOpener = SettingsOpener.shared

    /// Kept between rebuilds so tone-slider changes can redraw the graph in
    /// place while the menu stays open.
    private weak var quickEQBody: QuickEQBodyView?
    private var cancellables: Set<AnyCancellable> = []

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

    /// A list that is fading out and has still to be taken out of the menu.
    /// Held so nothing can be inserted around it while it is on its way out.
    private var foldingItem: NSMenuItem?
    private var foldTimer: Timer?

    init(
        profileManager: ProfileManager,
        audioEngine: AudioEngine,
        outputs: AudioDeviceList,
        openMainWindow: @escaping () -> Void
    ) {
        self.profileManager = profileManager
        self.audioEngine = audioEngine
        self.outputs = outputs
        self.openMainWindow = openMainWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.toolTip = "CoreEQ"
            settingsOpener.install(in: button)
        }
        updateStatusItemIcon()
        followEngineState()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Keeps the icon in step with the engine.
    ///
    /// The menu itself is rebuilt on open and needs no subscription, but the
    /// icon is the one thing that has to change while nobody is looking — that
    /// is the whole reason it carries the state.
    private func followEngineState() {
        // Delivered synchronously, and from the values Combine hands over.
        //
        // Two reasons, both of which showed up as the icon lagging. `@Published`
        // emits in `willSet`, so a sink that reads the engine back sees the
        // value being replaced and the icon trails a click behind. And hopping
        // through `RunLoop.main` delivers only in the default run loop mode,
        // while an open menu runs a nested loop in event tracking mode — so
        // clicking the switch in the menu left the icon unchanged until the menu
        // closed, which is precisely when nobody is looking at it.
        audioEngine.$isEnabled
            .combineLatest(audioEngine.$status)
            .sink { [weak self] isEnabled, status in
                self?.applyStatusIcon(for: .init(status: status, isEnabled: isEnabled))
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        expandedSection = nil
        listItem = nil
        disclosureRows.removeAll()
        sectionItems.removeAll()

        menu.addItem(headerItem())
        if let failure = engineFailureItem() {
            menu.addItem(failure)
        }
        menu.addItem(.separator())

        // Where the sound is going comes first, right under the switch that
        // decides whether it is being shaped at all. Both are questions about
        // the audio path; everything below them is about how it sounds.
        menu.addItem(.sectionHeader(title: "Output"))
        menu.addItem(outputItem())
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Preset"))
        menu.addItem(presetItem())
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Quick EQ"))
        menu.addItem(quickEQItem())
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open Equalizer…", action: #selector(openWindow(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // The tail every menu bar item in the system carries, and the only place
        // CoreEQ can carry it: as an accessory application it has no menu bar of
        // its own, so there is no App menu to hold Settings or Quit. Wi-Fi ends
        // in "Wi-Fi Settings…" for the same reason.
        //
        // About is not here. It is a tab of the Settings window, reached by the
        // gear in the main window or by clicking the app mark in its sidebar —
        // this row stays because the window is optional and the setting most
        // worth having, "Open at login", matters most to whoever never opens it.
        //
        // No key equivalents: a status menu's shortcuts only fire while the menu
        // is open, so ⌘, here would be a promise the app cannot keep.
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettingsItem(_:)), keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit CoreEQ", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Every open starts with both sections folded, so nothing is left holding
    /// on to rows from a menu that no longer exists.
    func menuDidClose(_ menu: NSMenu) {
        foldTimer?.invalidate()
        foldTimer = nil
        foldingItem = nil
        expandedSection = nil
        listItem = nil
        disclosureRows.removeAll()
        sectionItems.removeAll()
    }

    // MARK: - Items

    /// States an engine failure at the top of the menu, or nothing when the
    /// engine is fine.
    ///
    /// The menu is where a menu bar app's users actually are — many never open
    /// the main window at all — so a failure reported only there is, for most
    /// people, not reported.
    ///
    /// Shows the failure's short summary, not its message. A menu is as wide as
    /// its widest item and `NSMenuItem` titles do not wrap, so a sentence here
    /// drags the whole menu out to its length. The message has to say what to
    /// change, which makes it a sentence and the menu the wrong place for it:
    /// this names the fault, the tooltip carries the sentence, and the click
    /// opens the full report.
    /// What the menu bar icon says about the engine.
    ///
    /// The one signal visible without clicking anything, which for an accessory
    /// app with no window is the only way to say that something needs
    /// attention.
    private enum StatusIcon {
        case shaping
        case off
        case unavailable

        /// Two images for three states.
        ///
        /// "Is my audio being shaped" is the only question an icon this size can
        /// answer, and switched-off and cannot-run give it the same answer; why
        /// is a click away. An earlier attempt drew switched-off as flat bars,
        /// on the reasoning that the icon is a frequency response — but the
        /// curve is what makes it recognisable as CoreEQ, and levelling it read
        /// as a barcode.
        var resourceName: String {
            switch self {
            case .shaping: return "MenuBarIconTemplate"
            case .off, .unavailable: return "MenuBarIconSlashTemplate"
            }
        }

        /// Spoken by VoiceOver, and the icon's tooltip. Three labels where there
        /// are only two images: the tooltip has room to say which of the two
        /// reasons applies, and the icon does not.
        var label: String {
            switch self {
            case .shaping: return "CoreEQ"
            case .off: return "CoreEQ, equalizer off"
            case .unavailable: return "CoreEQ, not processing audio"
            }
        }
    }

    /// Everything the icon depends on, in one value that can be passed around
    /// rather than read back off the engine mid-change.
    private struct EngineState {
        let status: AudioEngine.Status
        let isEnabled: Bool

        var icon: StatusIcon {
            guard AudioEngine.canProcess(status: status) else { return .unavailable }
            return AudioEngine.isProcessing(status: status, isEnabled: isEnabled)
                ? .shaping : .off
        }
    }

    private func updateStatusItemIcon() {
        applyStatusIcon(for: .init(status: audioEngine.status, isEnabled: audioEngine.isEnabled))
    }

    private func applyStatusIcon(for state: EngineState) {
        guard let button = statusItem.button else { return }
        let icon = state.icon
        let image =
            NSImage(named: icon.resourceName)
            ?? NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = icon.label
        button.image = image
        button.toolTip = icon.label
    }

    /// Opacity for the EQ controls: the engine's own answer, not a rule of the
    /// menu's own. Off and failed both mean nothing is being shaped.
    private var eqControlsAlpha: CGFloat {
        audioEngine.isProcessing ? 1.0 : 0.45
    }

    private func engineFailureItem() -> NSMenuItem? {
        guard let summary = audioEngine.status.summary else { return nil }
        let awaiting: Bool
        if case .awaitingPermission = audioEngine.status {
            awaiting = true
        } else {
            awaiting = false
        }

        let item = NSMenuItem(
            title: summary,
            action: awaiting ? #selector(openPermission) : #selector(openDiagnostics),
            keyEquivalent: "")
        item.target = self
        item.image = NSImage(
            systemSymbolName:
                awaiting ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        item.toolTip = audioEngine.status.description
        return item
    }

    /// Permission is explained in Settings, not here: this row can hold about
    /// four words before the whole menu grows to its width.
    @objc private func openPermission() {
        SettingsOpener.shared.open(tab: .general)
    }

    @objc private func openDiagnostics() {
        SettingsOpener.shared.open(tab: .diagnostics)
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuHeaderView(
            isOn: audioEngine.isEnabled, isEnabled: audioEngine.canProcess
        ) { [weak self] isOn in
            self?.audioEngine.isEnabled = isOn
            self?.quickEQBody?.alphaValue = self?.eqControlsAlpha ?? 1.0
        }
        return item
    }

    /// The active preset, with a chevron that unfolds the others below it.
    ///
    /// Its badge is drawn from the working chain rather than from the preset as
    /// saved, so the thumbnail is the sound in the room right now — including
    /// any edits, which the dot after the name reports.
    private func presetItem() -> NSMenuItem {
        disclosureItem(
            for: .preset,
            title: profileManager.activeProfileName,
            image: presetBadge(for: profileManager.currentFilters, selected: true),
            gutter: MenuListMetrics.badgeGutter,
            height: MenuListMetrics.rowHeight,
            marker: profileManager.isModified,
            canExpand: profileManager.profiles.count > 1
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
        body.alphaValue = eqControlsAlpha
        quickEQBody = body

        let item = NSMenuItem()
        item.view = body
        return item
    }

    /// The device the sound is going to. Clicking it unfolds the others below
    /// it — unless the machine only has the one, when there is nothing to choose
    /// between: the row then states where the sound goes, without a chevron.
    private func outputItem() -> NSMenuItem {
        let current = outputs.devices.first { $0.id == outputs.defaultDeviceID }

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
            height: MenuListMetrics.rowHeight,
            canExpand: outputs.hasChoice
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
        marker: Bool = false,
        canExpand: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let row = MenuRowView(
            title: title,
            image: image,
            gutter: gutter,
            height: height,
            marker: marker,
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
        // Folding a list away is worth watching; swapping one list for another
        // is not, and letting the old one linger while the new one is inserted
        // would put two lists in the menu at once.
        collapse(in: menu, animated: wasOpen)
        guard !wasOpen else { return }
        expand(section, in: menu)
    }

    /// Takes the open list back out and turns its chevron back to `>`.
    ///
    /// Animated, the item stays in the menu for the length of the fade and is
    /// removed by a timer rather than by an animation completion block: a menu
    /// tracks in its own modal loop, where a block posted to the main queue may
    /// not run until the menu closes. The timer is added to `.common`, which
    /// includes the tracking mode, so it fires while the menu is still up.
    private func collapse(in menu: NSMenu, animated: Bool = false) {
        if let listItem, menu.index(of: listItem) >= 0 {
            if animated, let list = listItem.view as? MenuListView {
                let item = listItem
                list.playFold()
                foldingItem = item
                foldTimer?.invalidate()
                // Target / action rather than a closure: the item and the menu
                // are reached from `self` when it fires, so nothing non-sendable
                // has to be carried across.
                let timer = Timer(
                    timeInterval: MenuListMetrics.foldDuration,
                    target: self,
                    selector: #selector(foldTimerFired),
                    userInfo: nil,
                    repeats: false
                )
                RunLoop.main.add(timer, forMode: .common)
                foldTimer = timer
            } else {
                menu.removeItem(listItem)
            }
        }
        listItem = nil
        if let expandedSection {
            disclosureRows[expandedSection]?.setExpanded(false)
        }
        expandedSection = nil
    }

    @objc private func foldTimerFired() {
        guard let menu = statusItem.menu else { return }
        finishFold(in: menu)
    }

    /// Takes out a list that is still fading, before anything is inserted
    /// around it — otherwise a fast second click would leave the outgoing list
    /// in the menu, one row away from where its own removal expects it.
    private func finishFold(in menu: NSMenu) {
        foldTimer?.invalidate()
        foldTimer = nil
        if let foldingItem, menu.index(of: foldingItem) >= 0 {
            menu.removeItem(foldingItem)
        }
        foldingItem = nil
    }

    /// Inserts the section's other options directly under its row. The menu is
    /// open while this runs: AppKit re-lays it out around the new item, which is
    /// what makes the list appear in place rather than in a submenu.
    private func expand(_ section: ListSection, in menu: NSMenu) {
        finishFold(in: menu)
        guard let rowItem = sectionItems[section] else { return }
        let index = menu.index(of: rowItem)
        guard index >= 0 else { return }

        let rows: [MenuRowView]
        switch section {
        case .preset: rows = presetRows()
        case .output: rows = outputRows()
        }
        guard !rows.isEmpty else { return }

        let list = MenuListView(rows: rows, rowHeight: MenuListMetrics.rowHeight)
        let item = NSMenuItem()
        item.view = list
        menu.insertItem(item, at: index + 1)
        list.playUnfold()

        listItem = item
        expandedSection = section
        disclosureRows[section]?.setExpanded(true)
    }

    /// Every preset except the active one — that one is the row above, and
    /// repeating it here would only offer a choice that changes nothing. Its
    /// accent-filled badge stays up there too, so this list is all plain
    /// badges: what else there is, and what each one would sound like.
    private func presetRows() -> [MenuRowView] {
        let active = profileManager.activeProfileName
        return profileManager.profiles
            .filter { $0.name != active }
            .map { profile in
                MenuRowView(
                    title: profile.name,
                    image: presetBadge(for: profile.filters, selected: false),
                    gutter: MenuListMetrics.badgeGutter,
                    height: MenuListMetrics.rowHeight
                ) { [weak self] in
                    self?.profileManager.setActiveProfile(name: profile.name)
                    self?.dismissMenu()
                }
            }
    }

    /// Every output device except the one in use. Its accent-filled badge stays
    /// on the row above, so the list is all plain badges: what else there is.
    private func outputRows() -> [MenuRowView] {
        outputs.devices
            .filter { $0.id != outputs.defaultDeviceID }
            .map { device in
                MenuRowView(
                    title: device.name,
                    image: Self.deviceIcon(device.symbolName, selected: false),
                    gutter: MenuListMetrics.badgeGutter,
                    height: MenuListMetrics.rowHeight
                ) { [weak self] in
                    // Through the list, so the menu and the window's picker take
                    // the same route to a device change — including the optimistic
                    // update that keeps the selection from flicking back.
                    self?.outputs.select(device.id)
                    self?.dismissMenu()
                }
            }
    }

    /// Picking an option closes the menu, as picking one in a submenu did.
    private func dismissMenu() {
        statusItem.menu?.cancelTracking()
    }

    /// A preset's own response curve, in the same circular badge the devices
    /// wear.
    ///
    /// The two choosers are one control used twice, so they are drawn to one
    /// shape — same row height, same gutter, same badge, same accent fill on
    /// the one in use. What goes *in* the preset's badge is the thing that
    /// makes the badge worth its space: a repeated generic glyph on every row
    /// would be decoration, but a thumbnail of the curve says which preset is
    /// which before the name is read, and it is the same shape the big plot
    /// shows when the preset is chosen.
    ///
    /// The magnitudes are computed here, outside the drawing handler, so the
    /// handler captures numbers rather than the filter chain and the engine.
    private func presetBadge(for filters: [EQFilter], selected: Bool) -> NSImage? {
        let sampleRate = audioEngine.sampleRate
        let biquads = filters.map { Biquad(filter: $0, sampleRate: sampleRate) }

        // A couple of dozen points across the span the ear does its listening
        // in — enough for the shape, cheap enough to redraw for every preset
        // each time the menu opens.
        let steps = 24
        let low = log(32.0)
        let span = log(16_000.0) - low
        let curve: [Double] = (0..<steps).map { step in
            let frequency = exp(low + span * Double(step) / Double(steps - 1))
            return biquads.reduce(0.0) {
                $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
        }

        let side = MenuListMetrics.badgeSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12))
                .setFill()
            NSBezierPath(ovalIn: rect).fill()

            // The full slider range fills the box, so a preset that uses all of
            // it reaches the edges and a flat one is a line through the middle.
            let box = rect.insetBy(dx: 5, dy: 7)
            let limit = BuiltInProfiles.gainRange.upperBound
            let path = NSBezierPath()
            for (step, dB) in curve.enumerated() {
                let x = box.minX + box.width * CGFloat(step) / CGFloat(steps - 1)
                let y = box.midY + box.height / 2 * CGFloat(dB.clamped(to: -limit...limit) / limit)
                if step == 0 {
                    path.move(to: NSPoint(x: x, y: y))
                } else {
                    path.line(to: NSPoint(x: x, y: y))
                }
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (selected ? NSColor.white : NSColor.labelColor).setStroke()
            path.stroke()
            return true
        }
    }

    /// Renders a device SF Symbol inside a circular badge, Control-Center
    /// style: a translucent circle behind the glyph, or an accent-filled circle
    /// with a white glyph for the selected device. Drawn into a real bitmap
    /// because NSMenu ignores symbol configurations and lays out symbol images
    /// at its own standard size. The drawing handler runs at display time, so
    /// the dynamic colours resolve correctly for Light / Dark mode.
    private static func deviceIcon(_ symbolName: String, selected: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        else {
            return nil
        }
        let side: CGFloat = 28
        let glyphInset: CGFloat = 4
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12))
                .setFill()
            NSBezierPath(ovalIn: rect).fill()

            let glyphColor: NSColor = selected ? .white : .labelColor
            let tinted =
                symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [glyphColor])
                ) ?? symbol

            let box = rect.insetBy(dx: glyphInset, dy: glyphInset)
            let symbolSize = tinted.size
            guard symbolSize.width > 0, symbolSize.height > 0 else { return true }
            let scale = min(box.width / symbolSize.width, box.height / symbolSize.height)
            let drawSize = NSSize(
                width: symbolSize.width * scale, height: symbolSize.height * scale)
            let origin = NSPoint(
                x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
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
        refreshPresetRow()
    }

    /// Brings the preset row up to date without rebuilding the menu.
    ///
    /// The tone sliders edit the chain from inside the open menu, so the row
    /// three above them goes stale the moment they are touched: its dot said
    /// "saved" while the sliders were changing the sound, and its badge drew a
    /// curve that was no longer the one playing. Both are answers to "what is
    /// happening right now", so both follow the sliders.
    private func refreshPresetRow() {
        guard let row = disclosureRows[.preset] else { return }
        row.setMarker(profileManager.isModified)
        row.setImage(presetBadge(for: profileManager.currentFilters, selected: true))
    }

    @objc private func openWindow(_ sender: NSMenuItem) {
        openMainWindow()
    }

    @objc private func openSettingsItem(_ sender: NSMenuItem) {
        settingsOpener.open()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar column of the main window: the app mark, the preset list, and the
/// `+` menu and the AutoEQ guide in the bar along the bottom.
///
/// Hosted inside an `NSSplitViewItem(sidebarWithViewController:)`, which
/// supplies the sidebar material and the full-height layout that runs it up
/// behind the titlebar. The item's safe area keeps this content clear of the
/// window controls, so the view itself draws no background of its own.
struct EqualizerSidebarView: View {
    @ObservedObject var profileManager: ProfileManager

    /// Filters the list. Empty means everything, in sections.
    @State private var search = ""

    /// Whether the search field holds the keyboard.
    ///
    /// Tracked so that choosing a preset can hand it back: the click is the end
    /// of the search, and a caret still blinking in the field afterwards claims
    /// the typing continues.
    @FocusState private var searchFieldFocused: Bool

    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// Whether the app mark is under the pointer — its only affordance.
    @State private var isHoveringAppMark = false

    /// Preset the pointer is over, for the row's hover wash.
    @State private var hoveredPreset: String?

    /// Preset awaiting delete confirmation.
    @State private var deletionCandidate: String?

    /// Controls visibility of the AutoEQ guide sheet.
    @State private var showingAutoEQGuide = false
    /// Set by the guide's Paste button: the clipboard is read once the sheet
    /// has gone.
    @State private var pasteAfterGuide = false

    /// Error message from a failed file or clipboard import.
    @State private var importErrorMessage: String?
    @State private var exportErrorMessage: String?
    @State private var pendingImport: ProfileManager.ImportPreview?

    var body: some View {
        // A plain `VStack` rather than a `List` with safe-area insets: the header
        // is transparent so the sidebar material shows through it, which meant
        // an inset list scrolled its rows *underneath* and made them collide.
        // Stacking gives each piece its own region.
        VStack(alignment: .leading, spacing: 0) {
            appHeader

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            searchField

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if matches.user.isEmpty && matches.builtIn.isEmpty {
                            Text("No presets match “\(search)”.")
                                .font(Theme.Font.label)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                        }

                        // The user's own first: they are the ones worth finding,
                        // and there are two of them against twenty-two built-ins.
                        if !matches.user.isEmpty {
                            caption("My Presets")
                            ForEach(matches.user) { presetRow($0) }
                        }

                        if !matches.builtIn.isEmpty {
                            caption("Built-in")
                                .padding(.top, matches.user.isEmpty ? 0 : 12)
                            ForEach(matches.builtIn) { presetRow($0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                // Open on the active preset. Without this the list arrives at
                // whatever offset the first layout pass left it at, which for a
                // list taller than the window is the bottom.
                .onAppear { scroll.scrollTo(profileManager.activeProfileName, anchor: .center) }
            }
            .onDrop(of: [.fileURL, .text, .plainText], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }

            // Full width, as a sidebar's bottom bar is ruled off in AppKit.
            Divider()

            bottomBar
        }
        .alert(
            "Delete the preset “\(deletionCandidate ?? "")”?", isPresented: deletionAlertPresented
        ) {
            Button("Delete", role: .destructive) {
                if let name = deletionCandidate { profileManager.deleteProfile(named: name) }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("This preset will be removed permanently.")
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert(
            "Import Preset?",
            isPresented: Binding(
                get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })
        ) {
            Button("Import") {
                if let preview = pendingImport { _ = profileManager.commitImport(preview) }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            if let preview = pendingImport {
                Text(ImportSummary.message(for: preview))
            }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        // The guide's paste waits for the sheet to go, so the preview is the
        // same dialog every other import shows rather than a second one of
        // the guide's own.
        .sheet(
            isPresented: $showingAutoEQGuide,
            onDismiss: {
                guard pasteAfterGuide else { return }
                pasteAfterGuide = false
                previewClipboard()
            }
        ) {
            AutoEQGuideSheet {
                pasteAfterGuide = true
                showingAutoEQGuide = false
            }
        }
        // A preset created outside the sidebar arrives as a rename request; seed
        // the field with the generated name so typing replaces it.
        .onChange(of: profileManager.profileAwaitingRename) { _, name in
            if let name { renameText = name }
        }
        // ⌘V offers the clipboard import, but only when no text editor holds
        // the focus — a hidden `keyboardShortcut` here used to swallow ⌘V for
        // the whole window. See `ClipboardPasteCommand`.
        .background {
            ClipboardPasteCommand(isEnabled: !isPresentingModal) {
                previewClipboard()
            }
        }
    }

    /// True while a dialog or sheet is up, so ⌘V cannot open a second one behind
    /// it.
    private var isPresentingModal: Bool {
        pendingImport != nil || deletionCandidate != nil || importErrorMessage != nil
            || exportErrorMessage != nil || showingAutoEQGuide
    }

    /// App mark and name — an identity block that is also the way into About.
    ///
    /// Clicking an app's identity to see the app's identity is coherent, and
    /// unlike a link out to a web page it never takes anyone out of the app. It
    /// is a shortcut rather than the only route — the gear in the header reaches
    /// the same window — so it costs nothing if it is never found, which is what
    /// makes a hidden affordance acceptable here.
    ///
    /// At rest it is not a button: no border, no chevron, nothing claiming to be
    /// pressable. The hover wash and the pointing hand are the whole cue, which
    /// is what a Mac gives for something clickable that is not shaped like a
    /// control.
    private var appHeader: some View {
        Button {
            SettingsOpener.shared.open(tab: .about)
        } label: {
            HStack(spacing: 10) {
                AppMark()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("CoreEQ")
                        .font(Theme.Font.heading)
                    // States what CoreEQ does that Music.app's equalizer doesn't:
                    // it shapes every application's output, not one player's.
                    Text("System-wide equalizer")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHoveringAppMark ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringAppMark = $0 }
        .animation(.easeOut(duration: 0.12), value: isHoveringAppMark)
        .accessibilityLabel("About CoreEQ")
        .help("About CoreEQ")
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                // The same 13 pt the preset rows are set in: the field states
                // what the list below it is showing, so the two should read as
                // one control, and System Settings sizes its own sidebar search
                // to its rows the same way.
                .font(Theme.Font.body)
                .focused($searchFieldFocused)
                // Escape leaves the search as it was found.
                .onExitCommand {
                    search = ""
                    searchFieldFocused = false
                }

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var matches: (user: [EQProfile], builtIn: [EQProfile]) {
        profileManager.profiles(matching: search)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Font.value)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    /// One preset row.
    ///
    /// Hand-built rather than a `List` row because the selected state here is a
    /// low-opacity wash, and a `List`'s own selection is a saturated fill that
    /// can't be toned down. Everything a source list row owes the user — click
    /// to select, context menu, inline rename — is kept.
    private func presetRow(_ profile: EQProfile) -> some View {
        let isSelected = profile.name == profileManager.activeProfileName
        let isRenaming = profileManager.profileAwaitingRename == profile.name

        return HStack(spacing: 6) {
            if isRenaming {
                TextField("Preset Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { profileManager.profileAwaitingRename = nil }
                    .onAppear { renameFieldFocused = true }
                    // Clicking anywhere outside the field commits, the way
                    // Finder's inline rename does.
                    .onChange(of: renameFieldFocused) { _, isFocused in
                        if !isFocused { commitRename() }
                    }
            } else {
                Text(profile.name)
                    .font(Theme.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                // Unsaved changes as a dot rather than a word — the same mark
                // TextEdit puts in its close button.
                //
                // The only badge on the row. Which preset is active is said by
                // the selected row's fill, the way every source list on the Mac
                // says it; a checkmark beside it was the same fact told twice,
                // in the vocabulary of menus, which need a glyph only because
                // they have no selected row to tint. Leaving the trailing edge
                // to the dot is what makes the dot readable.
                if isSelected, profileManager.isModified {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill(isSelected: isSelected, isHovered: hoveredPreset == profile.name))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            if profileManager.profileAwaitingRename != nil { commitRename() }
            searchFieldFocused = false
            profileManager.setActiveProfile(name: profile.name)
        }
        .onHover { isInside in
            if isInside {
                hoveredPreset = profile.name
            } else if hoveredPreset == profile.name {
                hoveredPreset = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredPreset)
        .id(profile.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.name)
        .accessibilityValue(isSelected && profileManager.isModified ? "Edited" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .contextMenu { presetActions(for: profile.name) }
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        // The system accent, not CoreEQ's data colour: a source-list selection
        // is a control, and on a Mac set to blue this row should be blue.
        if isSelected { return .accentColor.opacity(0.18) }
        if isHovered { return .primary.opacity(0.06) }
        return .clear
    }

    /// The actions that belong to one preset, on its row's context menu.
    ///
    /// Creating, importing, and pasting live in the bar beneath the list, which
    /// is where they act on the library rather than on a row; a right
    /// click on a preset is about that preset, so this menu holds only what
    /// reads or writes it.
    @ViewBuilder
    private func presetActions(for name: String) -> some View {
        let isEditable = profileManager.canEditProfile(named: name)
        let isActive = name == profileManager.activeProfileName

        Button("Rename…") { profileManager.beginRename(of: name) }
            .disabled(!isEditable)

        Button("Duplicate") { profileManager.duplicateProfile(named: name) }

        Divider()

        Button("Save Changes") { profileManager.saveChangesToActiveProfile() }
            .disabled(!isEditable || !isActive || !profileManager.isModified)

        Button("Reset to Preset") { profileManager.resetToActiveProfile() }
            .disabled(!isActive || !profileManager.isModified)

        Divider()

        Menu("Export Preset") {
            Button("EqualizerAPO…") {
                showExportDialog(for: name, format: .equalizerAPO)
            }
            Button("CoreEQ…") {
                showExportDialog(for: name, format: .coreEQJSON)
            }
        }

        Divider()

        Button("Delete", role: .destructive) { deletionCandidate = name }
            .disabled(!isEditable)
    }

    // MARK: - Preset actions

    private enum PresetExportFormat {
        case equalizerAPO
        case coreEQJSON
    }

    private func commitRename() {
        guard let name = profileManager.profileAwaitingRename else { return }
        profileManager.profileAwaitingRename = nil
        profileManager.renameProfile(named: name, to: renameText)
    }

    private func showImportDialog() {
        let panel = NSOpenPanel()
        panel.title = "Import Preset"
        panel.message = "Choose an EqualizerAPO (.txt) or CoreEQ (.coreeq, .json) preset file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true

        var types: [UTType] = [.text, .plainText, .utf8PlainText, .json]
        if let txtType = UTType(filenameExtension: "txt") { types.append(txtType) }
        if let coreeqType = UTType(filenameExtension: "coreeq") { types.append(coreeqType) }
        panel.allowedContentTypes = Array(Set(types))

        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            previewFile(at: url)
        }
    }

    private func showExportDialog(for name: String, format: PresetExportFormat = .equalizerAPO) {
        let content: String
        let filename: String
        let allowedTypes: [UTType]
        switch format {
        case .equalizerAPO:
            do {
                content = try profileManager.exportProfileToEqualizerAPO(named: name)
            } catch {
                exportErrorMessage = error.localizedDescription
                return
            }
            filename = "\(name).txt"
            var types: [UTType] = [.text, .plainText, .utf8PlainText]
            if let txtType = UTType(filenameExtension: "txt") { types.append(txtType) }
            allowedTypes = Array(Set(types))
        case .coreEQJSON:
            do {
                content = try profileManager.exportProfileToJSON(named: name)
            } catch {
                exportErrorMessage = error.localizedDescription
                return
            }
            filename = "\(name).coreeq"
            var types: [UTType] = [.json, .text, .plainText]
            if let coreeqType = UTType(filenameExtension: "coreeq") { types.append(coreeqType) }
            allowedTypes = Array(Set(types))
        }

        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = allowedTypes
        panel.allowsOtherFileTypes = true

        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportErrorMessage = "Failed to export preset: \(error.localizedDescription)"
            }
        }
    }

    /// Shows an open or save panel as a sheet on the main window, or on its own
    /// when there is no window to attach it to.
    private func present(
        _ panel: NSSavePanel,
        then handler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        AppActivation.activate()
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in previewFile(at: url) }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        // Some sources drag a file as its path or URL in plain
                        // text. That is a file drop, and a file that cannot be
                        // read reports why — rather than falling through and
                        // parsing the path itself as a preset.
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: trimmed), url.isFileURL {
                            previewFile(at: url)
                        } else if FileManager.default.fileExists(atPath: trimmed) {
                            previewFile(at: URL(fileURLWithPath: trimmed))
                        } else {
                            previewText(text)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    // The view's only part in an import is reading the clipboard or naming the
    // file; parsing, naming, and adding all live in `ProfileManager`.

    private func previewFile(at url: URL) {
        do {
            pendingImport = try profileManager.previewImport(fileAt: url)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func previewText(_ text: String) {
        do {
            pendingImport = try profileManager.previewImport(text: text)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func previewClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            importErrorMessage = "The clipboard holds no preset text."
            return
        }
        previewText(text)
    }

    // MARK: - Bottom bar

    /// The bar under the list, holding what acts on the library rather than on
    /// one preset — the place Xcode's navigator and Reminders' sidebar keep
    /// their `+`.
    ///
    /// A borderless pull-down, so it is a real `NSPopUpButton` drawn the way
    /// AppKit draws one in a sidebar: a plain glyph, no bezel, no chevron.
    /// Deleting stays on the row's context menu, where the confirmation names
    /// the preset it removes. The AutoEQ guide sits at the other end.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("New Preset") {
                    profileManager.addProfile(filters: profileManager.currentFilters)
                }

                Divider()

                Button("Import Preset…") { showImportDialog() }

                // No key equivalent here: ⌘V is owned by `ClipboardPasteCommand`
                // so that it can defer to text editing. The hint lives in the
                // tooltip instead.
                Button("Paste Preset") { previewClipboard() }
                    .help("Paste a preset from the clipboard (⌘V)")
            } label: {
                // No font or colour here: AppKit draws a borderless pop-up's
                // image itself and ignores both, which is the point of using it.
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add Preset")
            .help("New or imported preset")

            Spacer(minLength: 0)

            // Borderless like the `+`, so both read as the bar's chrome: the
            // system draws the pair alike, and neither outshouts the list.
            Button {
                showingAutoEQGuide = true
            } label: {
                Label("AutoEQ", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Presets for your headphones from AutoEQ")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    // MARK: - Bindings

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }
}

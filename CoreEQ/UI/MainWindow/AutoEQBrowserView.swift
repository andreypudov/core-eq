import AppKit
import Combine
import SwiftUI

/// The AutoEQ catalog browser: a sheet for finding a headphone correction,
/// choosing how it was measured, hearing it, and keeping it.
///
/// The catalog has thousands of models, so the window is built around one
/// field and one list. Everything the list feeds — the measurement source, the
/// target curve, the audition — sits under it, in that order, because that is
/// the order the choice is made in.
///
/// The store and the manager are owned by the app and passed in. The window
/// reads their published state and drives them; it holds no model state of its
/// own beyond what the pointer is over and where the keyboard is. The window's
/// title bar names it, so the content starts with the search field.
struct AutoEQBrowserView: View {
    @ObservedObject var store: AutoEQStore
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var audioEngine: AudioEngine

    /// Closes the window. This view is a window's root rather than a sheet, so
    /// there is no presentation for `dismiss` to end; the app that owns the
    /// window hands the action in instead.
    let onClose: () -> Void

    /// Leaves the catalog for the by-hand import. The manual route ends in a
    /// preset that belongs to the sidebar list, so the app closes this window
    /// and puts the guide on the main window rather than presenting it here.
    let onImportByHand: () -> Void

    /// Model the pointer is over, for the row's hover wash.
    @State private var hoveredModel: String?

    /// The curve the graph draws: the preview once it arrives, and kept
    /// through the next selection's load so the graph never empties between
    /// two clicks. Cleared only when nothing is selected.
    @State private var displayedProfile: EQProfile?

    /// Set when the sheet reopens on a kept selection: its preview loads and
    /// draws, but does not play until asked. Opening the catalog never changes
    /// what is heard by itself. Cleared by the user's own choices only, so a
    /// catalog update or sample-rate change under a held preview keeps it held.
    @State private var auditionHeld = false

    /// Whether the search field holds the keyboard when the window opens.
    @FocusState private var searchFieldFocused: Bool

    /// A save that would change the correction, held until the user decides.
    /// The same sheet the manual import paths show, presented over the catalog.
    @State private var confirmationImport: ProfileManager.ImportPreview?

    /// Set when the confirmation sheet's Import is chosen: the catalog closes
    /// once that sheet is fully gone, so the window's dismissal never lands in
    /// the same run loop as the sheet's.
    @State private var closeAfterConfirmation = false

    /// The page size `AutoEQStore.searchResults` caps a search at. The count
    /// line says when the cap was reached rather than quoting a total it cannot
    /// know.
    private static let searchResultLimit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateContent

            Divider()

            attributionFooter
        }
        // A fixed size, not a floor. A sheet takes the size its content asks
        // for, and a list asks for the height of its rows: with only a minimum
        // the sheet grew and shrank with every keystroke of a search.
        .frame(width: 600, height: 680)
        .task {
            auditionHeld = store.selectedModelName != nil
            store.prepareForBrowserOpen()
            // First-use download starts here, never at app launch. Reopening
            // checks cache freshness before making an update request.
            await store.loadCatalog()
        }
        // Changing what is selected drops the preview, so Import cannot save a
        // curve that no longer matches the controls. The audition keeps
        // playing until the next one replaces it; see `selectionDidChange`.
        .onChange(of: store.selectedModelName) { _, _ in selectionDidChange() }
        .onChange(of: store.selectedVariant) { _, _ in selectionDidChange() }
        .onChange(of: store.selectedTargetLabel) { _, _ in selectionDidChange() }
        .onChange(of: store.catalogRevision) { _, _ in selectionDidChange() }
        .onChange(of: audioEngine.sampleRate) { _, _ in selectionDidChange() }
        .onChange(of: store.catalogState) { _, state in
            if state == .loaded && store.selectedModelName != nil { selectionDidChange() }
        }
        .onChange(of: store.previewProfile) { _, profile in
            guard let profile else { return }
            displayedProfile = profile
            if !auditionHeld { profileManager.beginAudition(profile) }
        }
        .onChange(of: store.selectedModelName) { _, name in
            guard name == nil else { return }
            displayedProfile = nil
            // Nothing selected, so nothing will replace what is playing.
            profileManager.endAudition()
        }
        .onChange(of: store.previewState) { _, state in
            // Neither will a correction that couldn't be loaded. Hearing the
            // previous model's curve under this one's error would be wrong.
            if case .failed = state { profileManager.endAudition() }
        }
        // The preview is the window's own. Leaving takes it down rather than
        // leaving a curve playing that the user can no longer see — a window's
        // `onDisappear` does not fire when it is only ordered out, so the
        // window's delegate ends the audition too. Ending it twice is safe.
        .onDisappear {
            store.cancelCatalogLoad()
            stopAuditionIfNeeded()
        }
        // Saving a correction CoreEQ would change goes through the same
        // disclosure sheet the manual import paths show, over the catalog.
        .sheet(item: $confirmationImport, onDismiss: closeAfterConfirmationIfNeeded) { preview in
            ImportConfirmationSheet(
                preview: preview,
                onConfirm: { choice in
                    profileManager.commitImport(preview, choice: choice)
                    closeAfterConfirmation = true
                    confirmationImport = nil
                },
                onCancel: { confirmationImport = nil }
            )
        }
    }

    /// Closes the catalog after an import, but only once the confirmation sheet
    /// has fully gone — dismissing the window while the sheet still animates
    /// away is the same one-into-another race the sidebar's sheets had.
    private func closeAfterConfirmationIfNeeded() {
        guard closeAfterConfirmation else { return }
        closeAfterConfirmation = false
        store.cancelPreview()
        onClose()
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.catalogState {
        case .idle, .loading:
            catalogLoadingView
        case .failed(let message):
            catalogErrorView(message)
        case .loaded:
            browserBody
        }
    }

    // MARK: - Catalog state

    private var catalogLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: store.catalogProgress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 260)
                .accessibilityLabel(store.catalogProgress.message)
            Text(store.catalogProgress.message)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            if case .downloading(let received, let total) = store.catalogProgress {
                Text(downloadSummary(received: received, total: total))
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") {
                cancel()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func downloadSummary(received: Int, total: Int?) -> String {
        let receivedText = ByteCountFormatter.string(
            fromByteCount: Int64(received), countStyle: .file)
        guard let total else {
            return String(
                localized: "\(receivedText) downloaded",
                comment: "AutoEq catalog download progress, size unknown, such as “2 MB downloaded”"
            )
        }
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return String(
            localized: "\(receivedText) of \(totalText)",
            comment: "AutoEq catalog download progress, such as “2 MB of 5 MB”")
    }

    /// The system's own empty state, so a failed load looks like every other
    /// app's "nothing here" rather than a layout of CoreEQ's.
    private func catalogErrorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load the AutoEq Catalog", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            // The guide works with no catalog at all: autoeq.app is reached in
            // the browser and the correction comes back through the clipboard,
            // so a failed load is not a dead end.
            HStack(spacing: 10) {
                Button("Import by Hand…") { onImportByHand() }

                Button("Try Again") {
                    Task { await store.loadCatalog(forceRefresh: true) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Browser

    private var browserBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchArea

            // The list is the one framed region, as a table in a macOS sheet
            // is; the controls under it sit on the sheet itself.
            resultsList
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.blockBorder, lineWidth: 1)
                )
                .padding(.horizontal, 16)

            bottomArea
        }
    }

    private var searchArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField

            // The count and, when it applies, the stale note share one line, so
            // a failed update check does not push the list down.
            HStack(spacing: 6) {
                Text(searchSummary)
                if store.catalogIsStale {
                    Spacer(minLength: 8)
                    Text("Using a saved catalog. Couldn’t check for updates.")
                        .lineLimit(1)
                    Button("Try Again") {
                        stopAuditionIfNeeded()
                        Task { await store.loadCatalog(forceRefresh: true) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(Theme.Font.secondary)
            .foregroundStyle(.secondary)
        }
        // The first content in the window now that the header is gone: enough
        // top padding that the field does not crowd the title bar.
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

            TextField("Search headphones", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($searchFieldFocused)
                .onExitCommand {
                    store.searchText = ""
                    searchFieldFocused = false
                }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
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
        .onAppear { searchFieldFocused = true }
    }

    @ViewBuilder
    private var resultsList: some View {
        if store.searchResults.isEmpty {
            emptyResults
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.searchResults) { model in
                            modelRow(model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                // Reopening on a kept selection shows its row, as the sidebar
                // shows the active preset.
                .onAppear {
                    if let name = store.selectedModelName {
                        scroll.scrollTo(name, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The system's search empty state — "No Results for …" with its own
    /// wording and symbol — the same one Finder and Mail show.
    @ViewBuilder
    private var emptyResults: some View {
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ContentUnavailableView("No Models", systemImage: "headphones")
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    /// One model row. Hand-built to match the sidebar's preset rows: the
    /// selected state is the same low-opacity accent wash, and the hover wash
    /// is the same weight, so the two lists read as the same kind of thing.
    private func modelRow(_ model: AutoEQModel) -> some View {
        let isSelected = model.name == store.selectedModelName
        let isHovered = hoveredModel == model.name

        return HStack(spacing: 8) {
            Text(model.name)
                .font(Theme.Font.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // How many measurements the model has, for the models that have
            // more than one. It is what makes choosing between two variants
            // meaningful, and it stays out of the way for the rest.
            if model.variants.count > 1 {
                Text("\(model.variants.count) measurements")
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill(isSelected: isSelected, isHovered: isHovered))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Selecting again would reset the measurement and target to the
            // model's defaults; on the selected row a click plays a held
            // preview instead, and otherwise does nothing.
            if isSelected {
                playHeldPreview()
            } else {
                auditionHeld = false
                store.selectModel(named: model.name)
            }
        }
        .onHover { isInside in
            if isInside {
                hoveredModel = model.name
            } else if hoveredModel == model.name {
                hoveredModel = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredModel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.name)
        .accessibilityValue(
            model.variants.count > 1
                ? String(
                    localized: "\(model.variants.count) measurements", bundle: .coreEQ,
                    comment: "AutoEq model row: how many measurements the model has")
                : ""
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return .accentColor.opacity(0.18) }
        if isHovered { return .primary.opacity(0.06) }
        return .clear
    }

    // MARK: - Configuration and actions

    /// Every part of this area keeps its size whatever is selected, loading or
    /// playing: the sheet is fixed, so anything here that grew or shrank would
    /// take its height from the list above and make the list jump.
    private var bottomArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            configurationCard

            statusView
                .frame(maxWidth: .infinity, minHeight: Self.statusHeight, alignment: .leading)
                .animation(.easeInOut(duration: 0.15), value: store.previewState)

            actionButtons
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Two lines of secondary text: the longest the status line says, the
    /// import notice, fits in it, so no message changes its height.
    private static let statusHeight: CGFloat = 30

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Labels leading and right-aligned against their pop-ups, the way a
            // macOS form sets them, so the two choices read as one column. The
            // model itself is not repeated here: it is the row selected above.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    formLabel("Measurement source:")
                    measurementControl
                }
                GridRow {
                    formLabel("Target curve:")
                    targetControl
                }
            }

            responsePreview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The graph's slot is always there. Before anything has played it holds a
    /// flat line; while the next selection loads it keeps the last curve,
    /// dimmed, rather than collapsing and reopening around every click.
    private var responsePreview: some View {
        let isCurrent = store.previewProfile != nil
        return GeometryReader { geometry in
            FrequencyResponseView(
                filters: displayedProfile?.filters ?? [],
                sampleRate: audioEngine.sampleRate,
                preamp: displayedProfile?.preamp ?? 0,
                compact: true,
                showsBackground: false
            )
            .frame(
                width: geometry.size.width * FrequencyResponseView.compactWidthFraction,
                height: geometry.size.width
                    * FrequencyResponseView.compactWidthFraction
                    / FrequencyResponseView.compactAspectRatio
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The outer frame gives the GeometryReader a real height;
        // the inner graph stays narrower and preserves its own ratio.
        .frame(height: FrequencyResponseView.compactPreviewHeight)
        .opacity(isCurrent ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: isCurrent)
        .accessibilityLabel("Preview response curve")
    }

    private func formLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.Font.body)
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Dropdowns

    /// Native pop-up buttons: each choice is one line, so the `Picker` that
    /// `PopUpMenuButton` stands in for elsewhere has nothing to get wrong here,
    /// and it brings the system's own face and check mark.
    ///
    /// With one option or none there is nothing to choose, so the value is
    /// stated as text instead — as the output device is when the Mac has only
    /// one. The pop-up stays in the layout, hidden, so the row is the same
    /// height either way and switching model never moves the graph.
    private var measurementControl: some View {
        let variants = store.availableVariants
        return Picker(
            "Measurement source",
            selection: Binding(
                get: { store.selectedVariant },
                set: { variant in
                    auditionHeld = false
                    variant.map(store.selectVariant)
                }
            )
        ) {
            if store.selectedVariant == nil {
                Text("Choose a model first").tag(AutoEQVariant?.none)
            }
            ForEach(variants, id: \.self) { variant in
                Text(variant.displayName).tag(Optional(variant))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .statedWhenSingle(
            variants.count <= 1,
            value: store.selectedVariant?.displayName,
            placeholder: String(
                localized: "Choose a model first", comment: "Measurement pop-up, before a model"),
            accessibilityLabel: String(
                localized: "Measurement source", comment: "Measurement pop-up, for VoiceOver")
        )
    }

    private var targetControl: some View {
        let targets = store.availableTargets
        return Picker(
            "Target curve",
            selection: Binding(
                get: { store.selectedTargetLabel },
                set: { label in
                    auditionHeld = false
                    label.map(store.selectTarget(label:))
                }
            )
        ) {
            if store.selectedTargetLabel == nil {
                Text("Choose a measurement first").tag(String?.none)
            }
            ForEach(targets) { target in
                Text(target.label).tag(Optional(target.label))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Only targets compatible with this measurement source, rig, and form are available")
        .statedWhenSingle(
            targets.count <= 1,
            value: store.selectedTargetLabel,
            placeholder: String(
                localized: "Choose a measurement first",
                comment: "Target pop-up, before a measurement"),
            accessibilityLabel: String(
                localized: "Target curve", comment: "Target pop-up, for VoiceOver")
        )
    }

    // MARK: - Status

    /// One line for what the preview is doing, at a fixed height. A correction
    /// CoreEQ would have to change says so here, in place of "Playing", since
    /// that is the one thing worth knowing before Import; the full list waits
    /// in the confirmation sheet.
    @ViewBuilder
    private var statusView: some View {
        if auditionHeld && store.previewState == .ready {
            HStack(spacing: 8) {
                Text("Last selection, not playing.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)

                Button("Play Preview") { playHeldPreview() }
                    .controlSize(.small)
            }
        } else if profileManager.isAuditioning && store.previewState == .ready {
            // Only once this selection's preview is the one playing. While the
            // next loads, the previous keeps playing and the status below says
            // what is happening.
            if store.previewWouldAdjust, let disclosure = store.previewCandidates?.disclosure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    Text(ImportSummary.notice(for: disclosure))
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text("Playing preview")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            switch store.previewState {
            case .ready:
                Text("Playing preview")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            case .idle:
                (store.selectedModelName == nil
                    ? Text("Choose a model to get started.")
                    : Text("Preview follows your selection."))
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    (store.selectedTargetLabel == AutoEQCatalogParser.defaultTargetLabel
                        ? Text("Loading correction…")
                        : Text("Computing correction in CoreEQ…"))
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)

                    Text(message)
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Try Again") {
                        store.schedulePreview(after: 0, sampleRate: audioEngine.sampleRate)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            // The other way to a preset, and the only one that works when the
            // catalog cannot help: muted and leading, so it never competes with
            // the actions on the model that is selected. Never disabled — it does
            // not depend on a selection, and it is the fallback in every state.
            // Kept at full strength: a dimmed title on a push button is how macOS
            // draws a disabled one, and the leading position is muting enough.
            Button("Import by Hand…") { onImportByHand() }
                .help("Import from AutoEq by hand")
                .accessibilityLabel("Import from AutoEq by hand")

            Spacer(minLength: 12)

            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)

            // The default-action shortcut alone makes it the blue default
            // button, as in any macOS dialog.
            Button("Import") { saveToPresets() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPreview)
        }
    }

    // MARK: - Attribution

    /// The credit line under everything, in every catalog state.
    ///
    /// Outside the results scroll view, so it stays put while the list moves,
    /// and small and tertiary the way a licence note is: present for the record
    /// rather than read.
    private var attributionFooter: some View {
        Text(attributionCredit)
            .font(Theme.Font.secondary)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    /// The line's licence and, once a measurement is chosen, who took it.
    private var attributionCredit: String {
        // Separate items, joined by the separator, rather than one sentence:
        // each stands alone and any can be missing.
        var credit = [
            String(
                localized: "Data from AutoEq · MIT, Jaakko Pasanen",
                comment: "AutoEq catalog credit: the data’s source and license")
        ]
        if let source = store.selectedVariant?.sourceDisplayName {
            credit.append(
                String(
                    localized: "measurement by \(source)",
                    comment:
                        "AutoEq catalog credit: who measured the headphones, such as “oratory1990”")
            )
        }
        if let target = store.selectedTargetLabel, target != AutoEQCatalogParser.defaultTargetLabel
        {
            credit.append(
                String(
                    localized: "computed by CoreEQ",
                    comment: "AutoEq catalog credit: CoreEQ computed this correction itself"))
        }
        return credit.joined(separator: " · ")
    }

    // MARK: - State

    private var searchSummary: String {
        let shown = store.searchResults.count
        let total = store.models.count
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            return String(
                localized: "\(total) models", bundle: .coreEQ,
                comment: "AutoEq catalog: how many headphone models it has")
        }
        if shown == 0 {
            return String(localized: "No matches", comment: "AutoEq catalog search: nothing found")
        }
        // The store caps a search at the page size, so a full page is reported
        // as the beginning of the matches rather than as all of them.
        if shown >= Self.searchResultLimit {
            return String(
                localized: "First \(Self.searchResultLimit) matches",
                comment: "AutoEq catalog search: only the first page of matches is shown")
        }
        return String(
            localized: "\(shown) matches", bundle: .coreEQ,
            comment: "AutoEq catalog search: how many models match")
    }

    /// Whether a current preview is ready to import.
    private var canPreview: Bool {
        store.previewState == .ready && store.previewProfile != nil
    }

    // MARK: - Actions

    /// Ends an audition if one is running. Used when the sheet goes or the
    /// selection moves on under it.
    private func stopAuditionIfNeeded() {
        profileManager.endAudition()
        store.cancelPreview()
    }

    /// A change of model, variant, or target schedules a debounced preview
    /// for the new selection, and leaves the current one playing until it
    /// arrives.
    ///
    /// Not a return to the original sound in between. Ending the audition here
    /// put the user's own preset back for the length of the debounce and the
    /// download, so every step through the list was heard as two changes —
    /// to the original sound and its preamp, then to the next correction.
    /// `beginAudition` swaps one preview for the next directly. Import stays
    /// unavailable meanwhile, because scheduling drops the old preview.
    private func selectionDidChange() {
        store.schedulePreview(sampleRate: audioEngine.sampleRate)
    }

    /// Starts the preview the sheet reopened with, when it is ready.
    private func playHeldPreview() {
        guard auditionHeld, let profile = store.previewProfile else { return }
        auditionHeld = false
        profileManager.beginAudition(profile)
    }

    private func cancel() {
        store.cancelCatalogLoad()
        profileManager.endAudition()
        store.cancelPreview()
        onClose()
    }

    /// Keeps the previewed chain as a user preset. Previewing follows the
    /// selection, so Import only commits the profile already being heard.
    ///
    /// The save runs through the same disclosure as every other import: a
    /// correction CoreEQ would have to change is held in the confirmation sheet
    /// until the user chooses, and one it can keep exact goes straight in.
    private func saveToPresets() {
        guard let candidates = store.previewCandidates, let profile = store.previewProfile,
            canPreview
        else { return }

        let preview = profileManager.previewImport(candidates: candidates, name: profile.name)
        if preview.requiresConfirmation {
            confirmationImport = preview
        } else {
            profileManager.commitImport(preview, choice: .keepExact)
            store.cancelPreview()
            onClose()
        }
    }
}

/// Routes the catalog into the main window's sheet. A counter makes every
/// click a distinct event, even when the sheet was dismissed moments earlier.
@MainActor
final class AutoEQBrowserRoute: ObservableObject {
    static let shared = AutoEQBrowserRoute()

    @Published private(set) var request = 0

    func requestBrowser() { request &+= 1 }

    private init() {}
}

/// How far a menu-style pop-up button sets its title in from its left edge,
/// measured on macOS 27. Text standing in for a pop-up is indented by the same
/// amount, so values in a form column start at one x whichever is shown.
private let popUpTitleInset: CGFloat = 12

extension View {
    /// Shows a value as plain text in place of this control when there is
    /// nothing to choose between. The control stays in the layout, hidden, so
    /// the row keeps the height it has with a choice.
    fileprivate func statedWhenSingle(
        _ isSingle: Bool, value: String?, placeholder: String, accessibilityLabel: String
    ) -> some View {
        opacity(isSingle ? 0 : 1)
            .allowsHitTesting(!isSingle)
            .accessibilityHidden(isSingle)
            .overlay(alignment: .leading) {
                if isSingle {
                    Text(value ?? placeholder)
                        .font(Theme.Font.body)
                        .padding(.leading, popUpTitleInset)
                        .foregroundStyle(
                            value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityValue(
                            value
                                ?? String(localized: "None", comment: "Pop-up value, for VoiceOver")
                        )
                }
            }
    }
}

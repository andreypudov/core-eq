import AppKit
import SwiftUI

/// The AutoEQ catalog browser: a window for finding a headphone correction,
/// choosing how it was measured, hearing it, and keeping it.
///
/// The catalog is six thousand models deep, so the window is built around one
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

    /// Whether the search field holds the keyboard when the window opens.
    @FocusState private var searchFieldFocused: Bool

    /// The page size `AutoEQStore.searchResults` caps a search at. The count
    /// line says when the cap was reached rather than quoting a total it cannot
    /// know.
    private static let searchResultLimit = 300

    /// Where the attribution footer sends its readers: the AutoEQ project every
    /// correction in this catalog comes from.
    private static let autoEQRepository = URL(string: "https://github.com/jaakkopasanen/AutoEq")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateContent

            Divider()

            attributionFooter
        }
        // A floor rather than a fixed size: the view is a window's content now,
        // so it lays out in whatever the window is given, and the window's own
        // minimum keeps the two dropdowns from truncating.
        .frame(minWidth: 600, minHeight: 520)
        .task {
            // Loaded once. Reopening the window reuses the catalog already in
            // the store; a failed load offers its own Retry rather than
            // refetching on every appearance.
            if store.catalogState == .idle {
                await store.loadCatalog()
            }
        }
        // Changing what is selected drops the preview and any audition with it,
        // so an action cannot apply a curve that no longer matches the controls.
        .onChange(of: store.selectedModelName) { _, _ in selectionDidChange() }
        .onChange(of: store.selectedVariant) { _, _ in selectionDidChange() }
        .onChange(of: store.selectedTargetLabel) { _, _ in selectionDidChange() }
        // The preview is the window's own. Leaving takes it down rather than
        // leaving a curve playing that the user can no longer see — a window's
        // `onDisappear` does not fire when it is only ordered out, so the
        // window's delegate ends the audition too. Ending it twice is safe.
        .onDisappear { stopAuditionIfNeeded() }
        // ⌘W, because CoreEQ is an accessory application with no main menu to
        // carry the standard Close key equivalent, and a shortcut declared in a
        // view belongs to the window that view is in.
        .background {
            Button("Close Window") { onClose() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
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
            ProgressView()
                .controlSize(.small)
            Text("Loading the AutoEq catalog…")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func catalogErrorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)

            Text("Couldn’t load the AutoEq catalog")
                .font(Theme.Font.heading)

            Text(message)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            // The guide works with no catalog at all: autoeq.app is reached in
            // the browser and the correction comes back through the clipboard,
            // so a failed load is not a dead end.
            HStack(spacing: 10) {
                Button("Retry") {
                    Task { await store.loadCatalog(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)

                Button("Import from AutoEq by Hand…") { onImportByHand() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Browser

    private var browserBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchArea

            resultsList

            Divider()

            bottomArea
        }
    }

    private var searchArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField

            Text(searchSummary)
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

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if store.searchResults.isEmpty {
                    emptyResults
                } else {
                    ForEach(store.searchResults) { model in
                        modelRow(model)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyResults: some View {
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(
            query.isEmpty ? "No models are available." : "No models match “\(query)”."
        )
        .font(Theme.Font.label)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
        .onTapGesture { store.selectModel(named: model.name) }
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
        .accessibilityValue(model.variants.count > 1 ? "\(model.variants.count) measurements" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return .accentColor.opacity(0.18) }
        if isHovered { return .primary.opacity(0.06) }
        return .clear
    }

    // MARK: - Configuration and actions

    private var bottomArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            configurationCard

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.15), value: store.previewState)

            actionButtons
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionSummary

            labeled("Measurement source") { measurementControl }
            labeled("Target curve") { targetControl }

            // A variant with no rig cannot be sent to AutoEQ's equalizer, so
            // the target choice does not apply to it. Say so rather than
            // offering a control that would silently do nothing.
            if store.selectedVariant != nil && !store.supportsCustomTargets {
                Text("This measurement uses AutoEq’s default target.")
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock()
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(store.selectedModelName ?? "No model selected")
                .font(Theme.Font.heading)
                .foregroundStyle(
                    store.selectedModelName == nil
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Text(selectionDetail)
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionDetail: String {
        guard let model = store.selectedModel else {
            return "Pick a model from the list to configure it."
        }
        let count = model.variants.count
        return count == 1 ? "1 measurement" : "\(count) measurements"
    }

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Dropdowns

    private var measurementControl: some View {
        let variants = store.availableVariants
        let isEnabled = !variants.isEmpty

        return PopUpMenuButton {
            measurementMenu()
        } label: {
            dropdownLabel(
                store.selectedVariant?.displayName ?? "Choose a model first",
                isEnabled: isEnabled
            )
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measurement source")
        .accessibilityValue(store.selectedVariant?.displayName ?? "None")
    }

    private var targetControl: some View {
        let targets = store.availableTargets
        let isEnabled = !targets.isEmpty && store.supportsCustomTargets

        return PopUpMenuButton {
            targetMenu()
        } label: {
            dropdownLabel(
                store.selectedTargetLabel ?? "Choose a measurement first",
                isEnabled: isEnabled
            )
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Target curve")
        .accessibilityValue(store.selectedTargetLabel ?? "None")
    }

    /// The control's own face: a filled rounded rect, the selected label, and
    /// the up-down chevron macOS puts on a pop-up button. Drawn rather than a
    /// `.roundedBorder` so it sits at the same weight as the search field above
    /// it, which is the same kind of control.
    private func dropdownLabel(_ title: String, isEnabled: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(
                    isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Image(systemName: "chevron.up.chevron.down")
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.blockBorder, lineWidth: 1)
        )
    }

    private func measurementMenu() -> NSMenu {
        let menu = NSMenu()
        for variant in store.availableVariants {
            let item = ActionMenuItem(title: variant.displayName) { [store] in
                store.selectVariant(variant)
            }
            item.state = variant == store.selectedVariant ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func targetMenu() -> NSMenu {
        let menu = NSMenu()
        for target in store.availableTargets {
            let item = ActionMenuItem(title: target.label) { [store] in
                store.selectTarget(label: target.label)
            }
            item.state = target.label == store.selectedTargetLabel ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        if profileManager.isAuditioning {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text("Auditioning “\(store.previewProfile?.name ?? "preview")”")
                    .font(Theme.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            switch store.previewState {
            case .idle:
                Text(
                    store.selectedModelName == nil
                        ? "Choose a model to get started." : "Ready to audition."
                )
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Building preview…")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                Text("Preview ready, \(store.previewProfile?.filters.count ?? 0) filters")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
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

                    Button("Retry") { startAudition() }
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
            Button("Import by Hand…") { onImportByHand() }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)
                .help("Import from AutoEq by hand")
                .accessibilityLabel("Import from AutoEq by hand")

            Spacer(minLength: 12)

            if profileManager.isAuditioning {
                Button("Stop Auditioning") { stopAudition() }
                    .buttonStyle(.bordered)

                Button("Save to My Presets") { saveToPresets() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Audition") { startAudition() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPreview)

                Button("Save to My Presets") { saveToPresets() }
                    .buttonStyle(.bordered)
                    .disabled(!canPreview)
            }
        }
    }

    // MARK: - Attribution

    /// The credit line under everything, in every catalog state.
    ///
    /// Outside the results scroll view, so it stays put while the list moves,
    /// and small and tertiary the way a licence note is: present for the record
    /// rather than read.
    private var attributionFooter: some View {
        HStack(spacing: 4) {
            Text("Corrections from")
            Link("AutoEq", destination: Self.autoEQRepository)
            Text(attributionCredit)
        }
        .font(Theme.Font.secondary)
        .foregroundStyle(.tertiary)
        .tint(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// The line's licence and, once a measurement is chosen, who took it.
    private var attributionCredit: String {
        var credit = "· MIT, Jaakko Pasanen"
        if let source = store.selectedVariant?.sourceDisplayName {
            credit += " · measurement by \(source)"
        }
        return credit
    }

    // MARK: - State

    private var searchSummary: String {
        let shown = store.searchResults.count
        let total = store.models.count
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            return "Showing \(shown.formatted()) of \(total.formatted()) models"
        }
        if shown == 0 {
            return "No matches"
        }
        // The store caps a search at the page size, so a full page is reported
        // as the beginning of the matches rather than as all of them.
        if shown >= Self.searchResultLimit {
            return "First \(Self.searchResultLimit) matches"
        }
        return shown == 1 ? "1 match" : "\(shown) matches"
    }

    /// Whether the current selection is complete enough to build a preview.
    private var canPreview: Bool {
        store.selectedModelName != nil
            && store.selectedVariant != nil
            && store.selectedTargetLabel != nil
            && store.previewState != .loading
    }

    // MARK: - Actions

    /// Fetches the selected profile and plays it. Called by both the primary
    /// action and the failure state's Retry.
    private func startAudition() {
        Task {
            if let profile = await store.loadSelectedProfile() {
                profileManager.beginAudition(profile)
            }
        }
    }

    private func stopAudition() {
        profileManager.endAudition()
        store.clearPreview()
    }

    /// Ends an audition if one is running. Used when the sheet goes or the
    /// selection moves on under it.
    private func stopAuditionIfNeeded() {
        guard profileManager.isAuditioning else { return }
        stopAudition()
    }

    /// A change of model, variant, or target invalidates the preview. Stopping
    /// the audition restores the state from before it; clearing the preview
    /// drops the curve so the next action builds one for the new selection.
    private func selectionDidChange() {
        stopAuditionIfNeeded()
        store.clearPreview()
    }

    /// Keeps the previewed chain as a user preset. Loads and auditions first
    /// when nothing is playing yet, so one click is enough from a cold start.
    private func saveToPresets() {
        Task {
            guard let profile = await ensureAuditioning() else { return }
            guard profileManager.isAuditioning else { return }
            if profileManager.saveAuditionAsPreset(named: profile.name) != nil {
                store.clearPreview()
                onClose()
            }
        }
    }

    private func ensureAuditioning() async -> EQProfile? {
        if profileManager.isAuditioning, store.previewState == .ready {
            return store.previewProfile
        }
        guard let profile = await store.loadSelectedProfile() else { return nil }
        profileManager.beginAudition(profile)
        return profile
    }
}

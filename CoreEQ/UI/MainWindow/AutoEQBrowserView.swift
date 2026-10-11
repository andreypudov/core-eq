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
        // minimum keeps the measurement dropdown from truncating.
        .frame(minWidth: 600, minHeight: 520)
        .task {
            store.resetSelectionForBrowserOpen()
            // First-use download starts here, never at app launch. Reopening
            // checks cache freshness before making an update request.
            await store.loadCatalog()
        }
        // Changing what is selected drops the preview and any audition with it,
        // so an action cannot apply a curve that no longer matches the controls.
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
            profileManager.beginAudition(profile)
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
        guard let total else { return "\(receivedText) downloaded" }
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "\(receivedText) of \(totalText)"
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
            if store.catalogIsStale {
                HStack {
                    Text("Using a saved catalog. Couldn’t check for updates.")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        stopAuditionIfNeeded()
                        Task { await store.loadCatalog(forceRefresh: true) }
                    }
                    .buttonStyle(.borderless)
                }
            }
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

            if store.previewWouldAdjust, let disclosure = store.previewCandidates?.disclosure {
                importAdjustmentNotice(for: disclosure)
            }

            labeled("Measurement source") { measurementControl }
            labeled("Target curve") { targetControl }

            if let profile = store.previewProfile {
                GeometryReader { geometry in
                    FrequencyResponseView(
                        filters: profile.filters,
                        sampleRate: audioEngine.sampleRate,
                        preamp: profile.preamp,
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
                .accessibilityLabel("Preview response curve")
            }

            if store.selectedVariant != nil {
                Text(
                    store.selectedTargetLabel == AutoEQCatalogParser.defaultTargetLabel
                        ? "Published correction by AutoEq"
                        : "Computed by CoreEQ using AutoEq target data"
                )
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
            }

            if store.selectedVariant != nil && !store.supportsCustomTargets {
                Text(
                    "No compatible alternative targets are available for this measurement. Uses AutoEq’s published correction."
                )
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock()
    }

    /// The notice under the selected model when saving the preview would change
    /// it: how many values CoreEQ would adjust, and how far that moves the
    /// response. The full disclosure waits in the confirmation sheet.
    private func importAdjustmentNotice(for disclosure: ImportDisclosure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Font.secondary)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(ImportSummary.notice(for: disclosure))
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving will adjust this correction")
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
        PopUpMenuButton {
            let menu = NSMenu()
            for target in store.availableTargets {
                let item = ActionMenuItem(title: target.label) { [store] in
                    store.selectTarget(label: target.label)
                }
                item.state = target.label == store.selectedTargetLabel ? .on : .off
                menu.addItem(item)
            }
            return menu
        } label: {
            dropdownLabel(
                store.selectedTargetLabel ?? "Choose a measurement first",
                isEnabled: !store.availableTargets.isEmpty)
        }
        .disabled(store.availableTargets.isEmpty)
        .accessibilityLabel("Target curve")
        .accessibilityValue(store.selectedTargetLabel ?? "None")
        .help("Only targets compatible with this measurement source, rig and form are available.")
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

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        if profileManager.isAuditioning {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text("Playing preview “\(store.previewProfile?.name ?? "preview")”")
                    .font(Theme.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            switch store.previewState {
            case .idle:
                Text(
                    store.selectedModelName == nil
                        ? "Choose a model to get started." : "Preview follows your selection."
                )
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        store.selectedTargetLabel == AutoEQCatalogParser.defaultTargetLabel
                            ? "Loading correction…" : "Computing correction in CoreEQ…"
                    )
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                }
            case .ready:
                Text("Playing preview, \(store.previewProfile?.filters.count ?? 0) filters")
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

                    Button("Retry") {
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
            Button("Import by Hand…") { onImportByHand() }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)
                .help("Import from AutoEq by hand")
                .accessibilityLabel("Import from AutoEq by hand")

            Spacer(minLength: 12)

            Button("Cancel") { cancel() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

            Button("Import") { saveToPresets() }
                .buttonStyle(.borderedProminent)
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
        HStack(spacing: 4) {
            Text("Data from")
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
        var credit = "AutoEq · MIT, Jaakko Pasanen"
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

    /// A change of model, variant, or target restores the original sound and
    /// schedules a debounced preview for the new selection.
    private func selectionDidChange() {
        stopAuditionIfNeeded()
        store.schedulePreview(sampleRate: audioEngine.sampleRate)
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

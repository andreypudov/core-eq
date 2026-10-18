import Combine
import Foundation

/// Drives the AutoEQ browser: owns the catalog, the current selection, and the
/// previewed profile.
///
/// UI-facing and main-actor bound; the network and cache work belongs to
/// `AutoEQNetworkService`, which it holds as an actor and calls with `await`.
@MainActor
final class AutoEQStore: ObservableObject {
    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum PreviewState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var previewState: PreviewState = .idle
    @Published private(set) var models: [AutoEQModel] = []
    @Published private(set) var targets: [AutoEQTarget] = []
    @Published private(set) var previewProfile: EQProfile?
    /// The exact and clipped chains behind `previewProfile`, or nil when no
    /// preview is loaded. Drives the browser's "this save would adjust" notice.
    @Published private(set) var previewCandidates: ImportCandidates?
    @Published private(set) var catalogProgress: AutoEQCatalogProgress = .checkingRevision
    @Published private(set) var catalogRevision: String = ""
    @Published private(set) var catalogIsStale = false

    @Published var searchText: String = "" {
        didSet { updateSearchResults() }
    }
    @Published private(set) var searchResults: [AutoEQModel] = []
    @Published var selectedModelName: String?
    @Published var selectedVariant: AutoEQVariant?
    @Published var selectedTargetLabel: String?

    private let service: AutoEQNetworkService
    private var catalog: AutoEQCatalog?
    /// Why the last catalog load failed, in English, for the diagnostics
    /// report. Nil once a load succeeds.
    private var lastFailureReason: String?
    /// Invalidates responses from preview requests that no longer match the
    /// current selection (or have been explicitly cleared).
    private var previewRequestID = UUID()
    private var previewTask: Task<Void, Never>?
    private var catalogTask: Task<AutoEQCatalog, any Error>?
    private var catalogRequestID = UUID()

    /// The alternative targets' download for the loaded revision: running, or
    /// finished successfully. A failed one is dropped, so the next call tries
    /// again. Shared, so a preview that needs a target waits on the same
    /// download the catalog started instead of starting its own.
    private var customTargetsTask: Task<Void, any Error>?
    private var customTargetsToken = UUID()

    init(service: AutoEQNetworkService = AutoEQNetworkService()) {
        self.service = service
    }

    // MARK: - Derived selection

    /// Models matching `searchText`, or the first page while the field is empty.
    var selectedModel: AutoEQModel? {
        guard let selectedModelName else { return nil }
        return models.first { $0.name == selectedModelName }
    }

    var availableVariants: [AutoEQVariant] {
        selectedModel?.variants ?? []
    }

    /// Published corrections plus upstream targets compatible with this measurement.
    var availableTargets: [AutoEQTarget] {
        guard let variant = selectedVariant else { return [] }

        return targets.filter {
            $0.supports(source: variant.source, rig: variant.rig, form: variant.form)
        }
    }

    // MARK: - Loading

    func loadCatalog(forceRefresh: Bool = false) async {
        cancelCatalogLoad()
        let requestID = UUID()
        catalogRequestID = requestID
        catalogProgress = .checkingRevision
        catalogState = .loading
        let service = service
        let task = Task {
            try await service.loadCatalog(forceRefresh: forceRefresh) { [weak self] progress in
                await self?.updateCatalogProgress(progress, requestID: requestID)
            }
        }
        catalogTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard catalogRequestID == requestID, !Task.isCancelled else { return }
            cancelPreview()
            catalog = loaded
            models = loaded.models
            targets = loaded.targets
            revalidateSelection()
            updateSearchResults()
            catalogRevision = loaded.revision
            catalogIsStale = loaded.isStale
            lastFailureReason = nil
            customTargetsTask = nil
            customTargetsToken = UUID()
            catalogState = .loaded
            // Published corrections remain available when target metadata is
            // offline; a preview that needs a target retries the download.
            try? await loadCustomTargets(revision: loaded.revision)
        } catch {
            guard catalogRequestID == requestID else { return }
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            {
                catalogState = catalog == nil ? .idle : .loaded
            } else {
                catalogState = .failed(Self.message(for: error))
                lastFailureReason = Self.diagnosticReason(for: error)
            }
        }
        if catalogRequestID == requestID { catalogTask = nil }
    }

    /// Adds the revision's alternative targets to `targets`, once. Throws the
    /// download's error, and a later call downloads again.
    private func loadCustomTargets(revision: String) async throws {
        let task: Task<Void, any Error>
        if let running = customTargetsTask {
            task = running
        } else {
            let service = service
            let token = UUID()
            customTargetsToken = token
            task = Task { [weak self] in
                let custom = try await service.loadTargets(revision: revision)
                // A catalog load replaced `targets` while this downloaded — even
                // to the same revision — and started its own download.
                guard let self, self.customTargetsToken == token else { return }
                self.targets += custom
            }
            customTargetsTask = task
        }
        do {
            try await task.value
        } catch {
            if customTargetsTask == task { customTargetsTask = nil }
            throw error
        }
    }

    func cancelCatalogLoad() {
        catalogTask?.cancel()
        catalogTask = nil
        catalogRequestID = UUID()
        if catalogState == .loading { catalogState = catalog == nil ? .idle : .loaded }
    }

    private func updateCatalogProgress(_ progress: AutoEQCatalogProgress, requestID: UUID) {
        guard requestID == catalogRequestID else { return }
        catalogProgress = progress
    }

    // MARK: - Selection

    /// Starts each presentation where the last one left off: the search, the
    /// model, its measurement and target are kept, since a return to the
    /// catalog is most often for the same headphones. Only the preview goes —
    /// the browser loads it again and decides whether it plays.
    ///
    /// The kept model must have a row to be seen in. An empty search lists only
    /// the first page of the catalog, and Escape in the field clears the search
    /// on the way to closing the sheet, so a model found by searching is
    /// usually off that page. When the search no longer shows it, it becomes
    /// the search.
    func prepareForBrowserOpen() {
        cancelPreview()
        if let name = selectedModelName, !searchResults.contains(where: { $0.name == name }) {
            searchText = name
        }
    }

    /// Drops a kept selection the loaded catalog no longer has, and moves a
    /// measurement it no longer lists back to the model's first. A target the
    /// new revision lacks needs no check here: the target menu offers only
    /// what the measurement supports, and loading the preview reports it.
    private func revalidateSelection() {
        guard let name = selectedModelName else { return }
        guard let model = models.first(where: { $0.name == name }) else {
            selectedModelName = nil
            selectedVariant = nil
            selectedTargetLabel = nil
            return
        }
        if let variant = selectedVariant, !model.variants.contains(variant) {
            selectModel(named: name)
        }
    }

    /// Selects a model, its first (highest-priority) variant, and a sensible
    /// default target.
    func selectModel(named name: String) {
        guard let model = models.first(where: { $0.name == name }) else { return }
        selectedModelName = model.name
        let variant = model.variants.first
        selectedVariant = variant
        selectedTargetLabel = variant.flatMap(defaultTargetLabel(for:))
    }

    /// Selects a variant, re-defaulting the target when the current one does not
    /// apply to it.
    func selectVariant(_ variant: AutoEQVariant) {
        guard availableVariants.contains(variant) else { return }
        selectedVariant = variant
        if let label = selectedTargetLabel,
            let target = targets.first(where: { $0.label == label }),
            target.supports(source: variant.source, rig: variant.rig, form: variant.form)
        {
            return
        }
        selectedTargetLabel = defaultTargetLabel(for: variant)
    }

    func selectTarget(label: String) {
        guard availableTargets.contains(where: { $0.label == label }) else { return }
        selectedTargetLabel = label
    }

    // MARK: - Preview

    /// Fetches and builds the profile for the current selection.
    @discardableResult
    func loadSelectedProfile(sampleRate: Double = 44_100) async -> EQProfile? {
        let requestID = UUID()
        previewRequestID = requestID
        guard let model = selectedModel, let variant = selectedVariant,
            let revision = catalog?.revision
        else {
            previewState = .idle
            previewProfile = nil
            previewCandidates = nil
            return nil
        }
        guard let targetLabel = selectedTargetLabel else {
            previewState = .failed(AutoEQError.noMatchingTarget.localizedDescription)
            previewProfile = nil
            previewCandidates = nil
            return nil
        }

        previewProfile = nil
        previewCandidates = nil
        previewState = .loading
        do {
            // An alternative target is never answered with the published
            // correction. Until its target list has arrived — just after the
            // catalog loads, or when its download failed — the preview waits
            // for it, and reports the download's error if there is one.
            var target: AutoEQTarget?
            if targetLabel != AutoEQCatalogParser.defaultTargetLabel {
                target = availableTargets.first { $0.label == targetLabel }
                if target == nil {
                    try await loadCustomTargets(revision: revision)
                    target = availableTargets.first { $0.label == targetLabel }
                }
                guard target != nil else { throw AutoEQError.noMatchingTarget }
            }

            let candidates: ImportCandidates
            if let target {
                let computed = try await service.computeProfile(
                    model: model.name, variant: variant, target: target, revision: revision)
                candidates = try AutoEQProfileBuilder.makeProfile(
                    model: model.name + " · " + targetLabel, equalized: computed,
                    sampleRate: sampleRate)
            } else {
                let text = try await service.fetchPrecomputedParametricEQ(
                    model: model.name, variant: variant, revision: revision)
                candidates = try AutoEQProfileBuilder.makeProfile(
                    model: model.name, parametricEQText: text, sampleRate: sampleRate)
            }
            guard !Task.isCancelled,
                previewRequestID == requestID,
                selectedModelName == model.name,
                selectedVariant == variant,
                selectedTargetLabel == targetLabel,
                catalog?.revision == revision
            else { return nil }
            // The graph and the audition hear the exact version; the disclosure
            // tells the browser whether saving it would change anything.
            previewCandidates = candidates
            previewProfile = candidates.exact
            previewState = .ready
            return candidates.exact
        } catch {
            guard !Task.isCancelled, previewRequestID == requestID else { return nil }
            previewProfile = nil
            previewCandidates = nil
            previewState = .failed(Self.message(for: error))
            return nil
        }
    }

    /// Follows a selection after a short pause, so moving through the model,
    /// measurement, or target lists does not make a request for every row.
    func schedulePreview(after delay: UInt64 = 300_000_000, sampleRate: Double = 44_100) {
        cancelPreview()
        previewTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            _ = await self.loadSelectedProfile(sampleRate: sampleRate)
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = UUID()
        previewProfile = nil
        previewCandidates = nil
        previewState = .idle
    }

    /// Whether saving the previewed correction would change it to fit CoreEQ.
    var previewWouldAdjust: Bool {
        previewCandidates?.disclosure.requiresConfirmation == true
    }

    // MARK: - Helpers

    /// The target supplied with the published correction.
    private func defaultTargetLabel(for variant: AutoEQVariant) -> String? {
        targets.first {
            $0.supports(source: variant.source, rig: variant.rig, form: variant.form)
        }?.label
    }

    private func updateSearchResults() {
        searchResults = catalog?.models(matching: searchText) ?? []
    }

    /// The catalog for the diagnostics report: what is cached, from the
    /// service, and how loading went this session.
    func diagnostics() -> DiagnosticsReport.AutoEQ {
        var report = service.cacheDiagnostics()
        switch catalogState {
        case .idle: report.session = .notOpened
        case .loading: report.session = .loading
        case .loaded: report.session = .loaded(isStale: catalogIsStale)
        case .failed: report.session = .failed(lastFailureReason ?? "unknown")
        }
        return report
    }

    private static func diagnosticReason(for error: any Error) -> String {
        if let error = error as? AutoEQError { return error.diagnosticReason }
        if let error = error as? URLError { return "network error \(error.code.rawValue)" }
        return String(describing: type(of: error))
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

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
    /// Invalidates responses from preview requests that no longer match the
    /// current selection (or have been explicitly cleared).
    private var previewRequestID = UUID()
    private var previewTask: Task<Void, Never>?
    private var catalogTask: Task<AutoEQCatalog, any Error>?
    private var catalogRequestID = UUID()

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

    /// Whether upstream supplies an alternative target for this measurement.
    var supportsCustomTargets: Bool {
        availableTargets.contains { $0.fr != nil }
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
            updateSearchResults()
            catalogRevision = loaded.revision
            catalogIsStale = loaded.isStale
            catalogState = .loaded
            do {
                let custom = try await service.loadTargets(revision: loaded.revision)
                guard catalogRequestID == requestID, !Task.isCancelled else { return }
                targets += custom
            } catch {
                guard catalogRequestID == requestID, !Task.isCancelled else { return }
                // Published corrections remain available when target metadata is offline.
            }
        } catch {
            guard catalogRequestID == requestID else { return }
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            {
                catalogState = catalog == nil ? .idle : .loaded
            } else {
                catalogState = .failed(Self.message(for: error))
            }
        }
        if catalogRequestID == requestID { catalogTask = nil }
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

    /// Starts each presentation in the documented empty state. Kept separate
    /// from catalog loading so retry and stale refresh preserve in-session work.
    func resetSelectionForBrowserOpen() {
        searchText = ""
        selectedModelName = nil
        selectedVariant = nil
        selectedTargetLabel = nil
        cancelPreview()
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
            let candidates: ImportCandidates
            if targetLabel != AutoEQCatalogParser.defaultTargetLabel,
                let target = availableTargets.first(where: { $0.label == targetLabel })
            {
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

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

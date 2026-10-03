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

    @Published var searchText: String = ""
    @Published var selectedModelName: String?
    @Published var selectedVariant: AutoEQVariant?
    @Published var selectedTargetLabel: String?

    private let service: AutoEQNetworkService
    private var catalog: AutoEQCatalog?
    /// Invalidates responses from preview requests that no longer match the
    /// current selection (or have been explicitly cleared).
    private var previewRequestID = UUID()

    init(service: AutoEQNetworkService = AutoEQNetworkService()) {
        self.service = service
    }

    // MARK: - Derived selection

    /// Models matching `searchText`, or the first page while the field is empty.
    var searchResults: [AutoEQModel] {
        catalog?.models(matching: searchText) ?? []
    }

    var selectedModel: AutoEQModel? {
        guard let selectedModelName else { return nil }
        return models.first { $0.name == selectedModelName }
    }

    var availableVariants: [AutoEQVariant] {
        selectedModel?.variants ?? []
    }

    /// Targets the selected variant can be corrected toward, recommended first.
    ///
    /// For a variant with no rig — which `/equalize` rejects — the list falls
    /// back to targets for the same source and form, so the UI can show what
    /// would apply while still disabling the action via `supportsCustomTargets`.
    var availableTargets: [AutoEQTarget] {
        guard let variant = selectedVariant else { return [] }

        func matches(_ target: AutoEQTarget) -> Bool {
            let pool = target.recommended + target.compatible
            if variant.rig != nil {
                return pool.contains {
                    $0.source == variant.source && $0.form == variant.form
                        && ($0.rig == nil || $0.rig == variant.rig)
                }
            }
            return pool.contains { $0.source == variant.source && $0.form == variant.form }
        }

        func isRecommended(_ target: AutoEQTarget) -> Bool {
            if variant.rig != nil {
                return target.recommended.contains {
                    $0.source == variant.source && $0.form == variant.form
                        && ($0.rig == nil || $0.rig == variant.rig)
                }
            }
            return target.recommended.contains {
                $0.source == variant.source && $0.form == variant.form
            }
        }

        let matched = targets.filter(matches)
        let recommended = matched.filter(isRecommended)
        let compatible = matched.filter { !isRecommended($0) }
        return recommended + compatible
    }

    /// Whether the selected variant can use AutoEQ's `/equalize` endpoint. When
    /// false the UI offers only the pre-computed fallback.
    var supportsCustomTargets: Bool {
        selectedVariant?.rig != nil
    }

    // MARK: - Loading

    func loadCatalog(forceRefresh: Bool = false) async {
        catalogState = .loading
        do {
            let loaded = try await service.loadCatalog(forceRefresh: forceRefresh)
            catalog = loaded
            models = loaded.models
            targets = loaded.targets
            catalogState = .loaded
        } catch {
            catalogState = .failed(Self.message(for: error))
        }
    }

    // MARK: - Selection

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
        selectedTargetLabel = label
    }

    // MARK: - Preview

    /// Fetches and builds the profile for the current selection.
    @discardableResult
    func loadSelectedProfile() async -> EQProfile? {
        let requestID = UUID()
        previewRequestID = requestID
        guard let model = selectedModel, let variant = selectedVariant,
            let targetLabel = selectedTargetLabel
        else {
            previewState = .failed(AutoEQError.noMatchingTarget.localizedDescription)
            previewProfile = nil
            return nil
        }

        previewProfile = nil
        previewState = .loading
        do {
            let profile: EQProfile
            if variant.rig != nil {
                let equalized = try await service.equalize(
                    model: model.name, variant: variant, targetLabel: targetLabel)
                profile = try AutoEQProfileBuilder.makeProfile(
                    model: model.name, equalized: equalized)
            } else {
                let text = try await service.fetchPrecomputedParametricEQ(
                    model: model.name, source: variant.source, form: variant.form)
                profile = try AutoEQProfileBuilder.makeProfile(
                    model: model.name, parametricEQText: text)
            }
            guard previewRequestID == requestID,
                selectedModelName == model.name,
                selectedVariant == variant,
                selectedTargetLabel == targetLabel
            else { return nil }
            previewProfile = profile
            previewState = .ready
            return profile
        } catch {
            guard previewRequestID == requestID else { return nil }
            previewProfile = nil
            previewState = .failed(Self.message(for: error))
            return nil
        }
    }

    func clearPreview() {
        previewRequestID = UUID()
        previewProfile = nil
        previewState = .idle
    }

    // MARK: - Helpers

    /// The first recommended target for a variant, or the first compatible one.
    private func defaultTargetLabel(for variant: AutoEQVariant) -> String? {
        func matches(_ candidate: AutoEQTargetVariant) -> Bool {
            guard candidate.source == variant.source && candidate.form == variant.form else {
                return false
            }
            // A blank rig in the target data is a form-wide entry, so it applies
            // to any rigged variant of that source and form.
            if variant.rig == nil { return candidate.rig == nil }
            return candidate.rig == nil || candidate.rig == variant.rig
        }
        let recommended = targets.first { $0.recommended.contains(where: matches) }
        let compatible = targets.first { $0.compatible.contains(where: matches) }
        return (recommended ?? compatible)?.label
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

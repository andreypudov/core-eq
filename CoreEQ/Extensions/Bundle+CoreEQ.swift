import Foundation

extension Bundle {
    /// The bundle CoreEQ's own code and String Catalog are built into.
    ///
    /// The app's main bundle, in the app. In the tests it is the test bundle,
    /// which compiles the same sources and the same catalog, while `.main` is
    /// the test runner, which has neither. Plural strings pass it, because
    /// only they read differently from their key: “1 filter” is a catalog
    /// variant of “%lld filters”, and without the catalog the tests would see
    /// “1 filters”. See docs/STRINGS.org.
    static let coreEQ = Bundle(for: BundleAnchor.self)
}

private final class BundleAnchor {}

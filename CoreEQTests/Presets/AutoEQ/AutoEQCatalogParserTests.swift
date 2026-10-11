import Foundation
import Testing

struct AutoEQCatalogParserTests {
    private func catalog(_ text: String = AutoEQTestFixtures.index) throws -> AutoEQCatalog {
        try AutoEQCatalogParser.parseIndex(Data(text.utf8), revision: AutoEQTestFixtures.revision)
    }

    @Test func sortsModelsAndPreservesExactPathsAndMeasurementOrder() throws {
        let catalog = try catalog()
        #expect(
            catalog.models.map(\.name) == ["Alpha Headphones", "Café Audio", "Zeta Headphones"])
        let alpha = try #require(catalog.models.first)
        #expect(alpha.variants.count == 2)
        #expect(alpha.variants[0].source == "oratory1990")
        #expect(alpha.variants[0].rig == "GRAS 43AG-7")
        #expect(alpha.variants[0].form == "over-ear")
        #expect(alpha.variants[0].resultPath == "oratory1990/GRAS 43AG-7 over-ear/Alpha Headphones")
        #expect(alpha.variants[1].source == "Rtings")
        #expect(catalog.models.last?.variants.first?.rig == nil)
        #expect(catalog.revision == AutoEQTestFixtures.revision)
    }

    @Test func excludesCrinacleAndDeduplicatesPaths() throws {
        let catalog = try catalog(AutoEQTestFixtures.index + "\n" + AutoEQTestFixtures.index)
        #expect(catalog.models.count == 3)
        #expect(catalog.models.first?.variants.count == 2)
        #expect(
            catalog.models.flatMap(\.variants).allSatisfy {
                !$0.source.lowercased().contains("crinacle")
            })
    }

    @Test func ignoresMalformedAndUnsafeLinks() throws {
        let unsafe = """
            - [Bad](./../over-ear/Bad) by unsafe
            - [Bad](./source/over-ear/%2E%2E) by unsafe
            - [Bad](./source/over-ear/Bad%2Fextra) by unsafe
            - [Bad](https://other.example/Bad) by unsafe
            - [Bad](./source/over-ear/Bad%ZZ) by unsafe
            """
        let catalog = try catalog(AutoEQTestFixtures.index + "\n" + unsafe)
        #expect(catalog.models.count == 3)
    }

    @Test func handlesParenthesesUnicodeAndReservedCharacters() throws {
        let catalog = try catalog(
            """
            - [A & B (ANC on)](./Source%20Name/711%20in-ear/A%20%26%20B%20(ANC%20on)) by Source Name on 711
            """)
        #expect(catalog.models.first?.name == "A & B (ANC on)")
        #expect(catalog.models.first?.variants.first?.source == "Source Name")
    }

    @Test func rejectsEmptyAndInvalidUTF8Indexes() {
        #expect(throws: AutoEQError.emptyCatalog) {
            _ = try catalog("# Index\n")
        }
        #expect(throws: AutoEQError.malformedData) {
            _ = try AutoEQCatalogParser.parseIndex(
                Data([0xFF]), revision: AutoEQTestFixtures.revision)
        }
    }

    @Test func preservesUpstreamZeroWidthSpacesInNamesAndPaths() throws {
        let catalog = try catalog(
            """
            - [Gaming Headset](./Rtings/HMS%20II.3%20over-ear/Gaming%20Headset%E2%80%8B) by Rtings
            """)
        #expect(catalog.models.first?.name == "Gaming Headset\u{200B}")
        #expect(catalog.models.first?.variants.first?.resultPath?.hasSuffix("\u{200B}") == true)
    }

    @Test func onlyOffersThePublishedTargetIncludingForMeasurementsWithoutRig() throws {
        let catalog = try catalog()
        #expect(catalog.targets.map(\.label) == [AutoEQCatalogParser.defaultTargetLabel])
        #expect(catalog.targets[0].supports(source: "oratory1990", rig: nil, form: "over-ear"))
    }

    @Test func targetRigWildcardMatchesConcreteRigsButRejectsMismatchedSourceAndForm() {
        let wildcard = AutoEQTarget(
            label: "Form-wide",
            compatible: [
                .init(source: "oratory1990", rig: nil, form: "over-ear")
            ], recommended: [])
        #expect(wildcard.supports(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear"))
        #expect(!wildcard.supports(source: "Rtings", rig: "GRAS 43AG-7", form: "over-ear"))
        #expect(!wildcard.supports(source: "oratory1990", rig: "GRAS 43AG-7", form: "in-ear"))

        let exactRig = AutoEQTarget(
            label: "Rig-specific",
            compatible: [
                .init(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")
            ], recommended: [])
        #expect(!exactRig.supports(source: "oratory1990", rig: "B&K 5128", form: "over-ear"))
    }

    @Test func searchIsCaseAndDiacriticInsensitiveAndLimited() throws {
        let catalog = try catalog()
        #expect(catalog.models(matching: "cafe").map(\.name) == ["Café Audio"])
        #expect(catalog.models(matching: "HEADPHONES").count == 2)
        #expect(catalog.models(matching: " ", limit: 2).count == 2)
        #expect(catalog.models(matching: "alpha", limit: 0).isEmpty)
    }

    @Test func variantDisplayNameReadsAsAMeasurementLabel() {
        let variant = AutoEQVariant(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")
        #expect(variant.displayName == "Oratory1990 · over-ear (GRAS 43AG-7)")
        #expect(AutoEQVariant(source: "Rtings", form: "in-ear").displayName == "Rtings · in-ear")
    }
}

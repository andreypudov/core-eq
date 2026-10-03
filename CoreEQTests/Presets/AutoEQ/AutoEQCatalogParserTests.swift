import Foundation
import Testing

struct AutoEQCatalogParserTests {
    @Test func parseEntriesSortsNamesCaseInsensitively() throws {
        let models = try AutoEQCatalogParser.parseEntries(AutoEQTestFixtures.entriesData)
        #expect(models.map(\.name) == ["Alpha Headphones", "Café Audio", "Zeta Headphones"])
    }

    @Test func parseEntriesPreservesVariantOrderAndFields() throws {
        let models = try AutoEQCatalogParser.parseEntries(AutoEQTestFixtures.entriesData)
        let alpha = try #require(models.first { $0.name == "Alpha Headphones" })
        #expect(alpha.variants.count == 2)
        #expect(alpha.variants[0].source == "oratory1990")
        #expect(alpha.variants[0].rig == "GRAS 43AG-7")
        #expect(alpha.variants[0].form == "over-ear")
        #expect(alpha.variants[1].source == "crinacle")
        #expect(alpha.variants[1].rig == nil)
        #expect(alpha.variants[1].form == "in-ear")
    }

    @Test func parseTargetsDecodesCompatibility() throws {
        let targets = try AutoEQCatalogParser.parseTargets(AutoEQTestFixtures.targetsData)
        #expect(targets.count == 3)
        let overEar = try #require(targets.first { $0.label == "Harman over-ear 2013" })
        #expect(overEar.compatible.count == 1)
        #expect(overEar.recommended.count == 1)
        #expect(overEar.recommended[0].rig == "GRAS 43AG-7")
    }

    @Test func targetSupportsMatchesExactVariantOnly() throws {
        let targets = try AutoEQCatalogParser.parseTargets(AutoEQTestFixtures.targetsData)
        let tolerated = try #require(targets.first { $0.label == "Harman over-ear 2018" })
        #expect(tolerated.supports(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear"))
        #expect(!tolerated.supports(source: "oratory1990", rig: nil, form: "over-ear"))
        #expect(!tolerated.supports(source: "crinacle", rig: "GRAS 43AG-7", form: "over-ear"))
    }

    @Test func targetWithBlankRigAppliesToAnyRig() throws {
        // AutoEQ lists form-wide sources (oratory1990 and most others) without a
        // rig. A blank rig means "any rig", so it must match a variant that has
        // one; otherwise nearly every target disappears from the dropdown.
        let json = """
            [
              {
                "label": "Form-wide over-ear",
                "compatible": [{"source": "oratory1990", "form": "over-ear"}],
                "recommended": [],
                "bassBoost": {}
              }
            ]
            """
        let targets = try AutoEQCatalogParser.parseTargets(Data(json.utf8))
        let target = try #require(targets.first)

        #expect(target.supports(source: "oratory1990", rig: "GRAS 45BC-10", form: "over-ear"))
        #expect(target.supports(source: "oratory1990", rig: nil, form: "over-ear"))
        #expect(!target.supports(source: "crinacle", rig: "GRAS 45BC-10", form: "over-ear"))
        #expect(!target.supports(source: "oratory1990", rig: "GRAS 45BC-10", form: "in-ear"))
    }

    @Test func malformedJSONThrowsMalformedData() {
        let bad = Data("not json".utf8)
        do {
            _ = try AutoEQCatalogParser.parseEntries(bad)
            Issue.record("expected parseEntries to throw")
        } catch {
            #expect(error as? AutoEQError == .malformedData)
        }
        do {
            _ = try AutoEQCatalogParser.parseTargets(bad)
            Issue.record("expected parseTargets to throw")
        } catch {
            #expect(error as? AutoEQError == .malformedData)
        }
    }

    @Test func modelsMatchingIsCaseInsensitive() throws {
        let models = try AutoEQCatalogParser.parseEntries(AutoEQTestFixtures.entriesData)
        let catalog = AutoEQCatalog(models: models, targets: [])
        #expect(catalog.models(matching: "zeta").map(\.name) == ["Zeta Headphones"])
        #expect(catalog.models(matching: "HEADPHONES").count == 2)
    }

    @Test func modelsMatchingIsDiacriticInsensitive() throws {
        let models = try AutoEQCatalogParser.parseEntries(AutoEQTestFixtures.entriesData)
        let catalog = AutoEQCatalog(models: models, targets: [])
        #expect(catalog.models(matching: "cafe").map(\.name) == ["Café Audio"])
    }

    @Test func modelsMatchingEmptyQueryRespectsLimit() throws {
        let models = try AutoEQCatalogParser.parseEntries(AutoEQTestFixtures.entriesData)
        let catalog = AutoEQCatalog(models: models, targets: [])
        #expect(catalog.models(matching: "").count == 3)
        #expect(
            catalog.models(matching: "", limit: 2).map(\.name) == [
                "Alpha Headphones", "Café Audio",
            ])
        #expect(catalog.models(matching: "alpha", limit: 0).isEmpty)
    }

    @Test func variantDisplayNameReadsAsAMeasurementLabel() {
        let variant = AutoEQVariant(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")
        #expect(variant.displayName == "Oratory1990 · over-ear (GRAS 43AG-7)")
        let noRig = AutoEQVariant(source: "rtings", rig: nil, form: "in-ear")
        #expect(noRig.displayName == "Rtings · in-ear")
    }
}

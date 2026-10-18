import Testing

struct SearchQueryTests {
    private func match(_ query: String, _ name: String) -> SearchQuery.Match? {
        SearchQuery(query).match(SearchableName(name))
    }

    /// The report that started this: the name has a hyphen, the query a space.
    @Test func punctuationInTheNameDoesNotHaveToBeTyped() {
        #expect(match("sony mdr m1", "Sony MDR-M1") == .wordStart)
        #expect(match("sony mdr-m1", "Sony MDR-M1") == .wordStart)
        #expect(match("Sony MDR-M1", "Sony MDR M1") == .wordStart)
    }

    @Test func wordsMatchInAnyOrder() {
        #expect(match("m1 sony", "Sony MDR-M1") == .wordStart)
        #expect(match("mdr", "Sony MDR-M1") == .wordStart)
    }

    /// Model numbers are written with and without their separators, and a
    /// person types whichever one they remember.
    @Test func modelNumbersMatchWithOrWithoutSeparators() {
        #expect(match("mdrm1", "Sony MDR-M1") == .wordStart)
        #expect(match("hd600", "Sennheiser HD 600") == .wordStart)
        #expect(match("hd 600", "Sennheiser HD600") == .wordStart)
        #expect(match("600", "Sennheiser HD600") == .wordStart, "digits after letters start a word")
        #expect(match("1000xm4", "Sony WH-1000XM4") == .wordStart)
    }

    @Test func aWordInsideAnotherStillMatchesButRanksLower() {
        #expect(match("booster", "Bass Booster") == .wordStart)
        #expect(match("oost", "Bass Booster") == .inside)
        #expect(match("sony dr", "Sony MDR-M1") == .inside, "the weakest word decides")
    }

    /// Every typed word must be there: this is not fuzzy matching.
    @Test func everyWordHasToBeFound() {
        #expect(match("sony m2", "Sony MDR-M1") == nil)
        #expect(match("smm1", "Sony MDR-M1") == nil, "letters in order are not a match")
        #expect(match("sonyy", "Sony MDR-M1") == nil, "nor is a near miss")
    }

    @Test func caseAccentsAndWidthAreIgnored() {
        #expect(match("CAFE", "Café") == .wordStart)
        #expect(match("café", "Cafe") == .wordStart)
        #expect(match("ｈｄ６００", "HD 600") == .wordStart)
    }

    @Test func whitespaceAndPunctuationAloneAreNotASearch() {
        #expect(SearchQuery("").isEmpty)
        #expect(SearchQuery("  ").isEmpty)
        #expect(SearchQuery(" - / ").isEmpty)
        #expect(!SearchQuery("a").isEmpty)
    }

    @Test func aWordLongerThanTheNameIsNotFound() {
        #expect(match("sennheiser", "HD") == nil)
        #expect(match("x", "") == nil)
    }

    /// Word-start matches first; otherwise the list's own order, untouched.
    @Test func rankingPutsWordStartsFirstAndKeepsOrderOtherwise() {
        let names = [
            "HiFiMan Sundara", "Sony MDR-7506", "Moondrop Aria", "Audeze LCD-2", "HiFiMan Arya",
        ]
        let ranked = SearchQuery("ar").ranked(names) { SearchableName($0) }
        #expect(ranked == ["Moondrop Aria", "HiFiMan Arya", "HiFiMan Sundara"])
    }
}

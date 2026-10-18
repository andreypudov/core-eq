import Foundation

/// What was typed into a search field, and the rule for which names it finds.
///
/// One rule for both of CoreEQ's searches, the sidebar's presets and the AutoEq
/// catalog, modelled on how Music, Mail, and System Settings search: each typed
/// word is matched on its own, in any order, ignoring case, accents, and
/// punctuation. "sony mdr m1" and "m1 sony" both find Sony MDR-M1.
///
/// Punctuation is ignored on both sides, and a word is looked for in the name
/// with its separators taken out, because headphone names are model numbers
/// written every way at once: "HD 600" and "HD600", "MDR-M1" and "MDR M1". A
/// person types whichever one they remember, so "hd600", "mdrm1", and "600" all
/// have to land.
///
/// Deliberately not fuzzy. Every result contains what was typed, punctuation
/// aside, so nothing turns up that the person can't explain. Letters-in-order
/// matching over thousands of similar names finds mostly noise, and the
/// popularity ranking that makes it work in a store's search is data CoreEQ
/// doesn't have.
struct SearchQuery: Sendable {
    /// How well a name matched, best first.
    enum Match: Int, Comparable, Sendable {
        /// Every typed word starts a word in the name: "m1" in "MDR-M1".
        case wordStart
        /// At least one typed word only appears inside a word: "dr" in "MDR".
        case inside

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let words: [[Character]]

    init(_ text: String) {
        words = SearchableName.words(in: text)
    }

    /// Whitespace and punctuation alone are not a search.
    var isEmpty: Bool { words.isEmpty }

    /// How `name` matches, or nil when some typed word isn't in it.
    func match(_ name: SearchableName) -> Match? {
        var result = Match.wordStart
        for word in words {
            guard let found = name.find(word) else { return nil }
            result = max(result, found)
        }
        return result
    }

    /// The items whose names match, those matching at the start of words
    /// first. Otherwise in the order given, so a search never shuffles a list
    /// that already had an order of its own.
    func ranked<Item>(_ items: [Item], name: (Item) -> SearchableName) -> [Item] {
        var starts: [Item] = []
        var inside: [Item] = []
        for item in items {
            switch match(name(item)) {
            case .wordStart: starts.append(item)
            case .inside: inside.append(item)
            case nil: break
            }
        }
        return starts + inside
    }
}

/// A name prepared for searching: folded, with its separators taken out, and
/// a note of where each of its words began.
///
/// Worth keeping when the same names are searched on every keystroke, as the
/// AutoEq catalog's few thousand are.
struct SearchableName: Sendable, Hashable {
    private let characters: [Character]
    private let isWordStart: [Bool]

    init(_ name: String) {
        var characters: [Character] = []
        var isWordStart: [Bool] = []
        for word in Self.words(in: name) {
            for (offset, character) in word.enumerated() {
                // A change between letters and digits starts a word too, so
                // "600" begins one in "HD600" just as it does in "HD 600".
                let startsWord =
                    offset == 0 || character.isNumber != word[offset - 1].isNumber
                characters.append(character)
                isWordStart.append(startsWord)
            }
        }
        self.characters = characters
        self.isWordStart = isWordStart
    }

    /// Where `word` appears, preferring an occurrence at the start of a word.
    fileprivate func find(_ word: [Character]) -> SearchQuery.Match? {
        guard let first = word.first, word.count <= characters.count else { return nil }
        var found: SearchQuery.Match?
        for start in 0...(characters.count - word.count) where characters[start] == first {
            guard characters[start..<start + word.count].elementsEqual(word) else { continue }
            if isWordStart[start] { return .wordStart }
            found = .inside
        }
        return found
    }

    /// The words in `text`, folded: lowercase, without accents, split at
    /// anything that is neither a letter nor a digit.
    fileprivate static func words(in text: String) -> [[Character]] {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
        )
        .split { !$0.isLetter && !$0.isNumber }
        .map(Array.init)
    }
}

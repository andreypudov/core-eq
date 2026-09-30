import Foundation

/// Parses equalization profiles from standard EqualizerAPO / AutoEQ text format
/// as well as native `.coreeq` JSON files.
///
/// Handles EqualizerAPO filter declarations:
/// ```text
/// Preamp: -6.4 dB
/// Filter 1: ON PK Fc 28 Hz Gain 6.2 dB Q 2.10
/// Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
/// Filter 3: ON HSC Fc 8000 Hz Gain -3.0 dB Q 0.70
/// Filter 4: ON HP Fc 20 Hz Q 0.71
/// Filter 5: ON LP Fc 20000 Hz Q 0.71
/// ```
enum ParametricEQParser {
    enum ParseError: Error, LocalizedError, Equatable {
        case emptyContent
        case noValidFiltersFound
        case unsupportedFilterDeclaration
        /// Starts like a `.coreeq` file but does not decode as one.
        case damagedCoreEQFile
        case fileTooLarge
        /// Bytes that are not text in any encoding a preset is written in.
        case unreadableText

        var errorDescription: String? {
            switch self {
            case .emptyContent:
                return "The preset content is empty."
            case .noValidFiltersFound:
                return "No valid filters were found in the preset text."
            case .unsupportedFilterDeclaration:
                return "The preset contains an unsupported filter declaration."
            case .damagedCoreEQFile:
                return "The CoreEQ preset is damaged and cannot be read."
            case .fileTooLarge:
                return "The file is too large to be a preset."
            case .unreadableText:
                return "The file is not a text preset."
            }
        }
    }

    /// Larger than any preset — a full AutoEQ file is under a kilobyte — and
    /// small enough that reading it on the main actor is not noticed.
    static let maxFileSize = 1_000_000

    /// Result of parsing an EqualizerAPO / AutoEQ text representation.
    struct ParsedPreset: Equatable {
        var name: String
        var preamp: Double
        var autoGain: Bool
        var filters: [EQFilter]

        /// How many free filters exceed `BuiltInProfiles.maxFreeFilters` and were
        /// trimmed away. Zero when everything parsed fits.
        var droppedFilterCount: Int = 0

        /// Non-comment lines that are neither a Preamp nor a parsed Filter
        /// declaration — for example `GraphicEQ:`, `Convolution:`, or `Channel:`.
        /// Kept for the caller to report; they are informational, never fatal.
        var unparsedLines: [String] = []

        /// Values outside CoreEQ's ranges — gain and preamp ±12 dB, frequency
        /// 20 Hz–20 kHz, Q 0.1–10 — that were clamped to fit. Counted over the
        /// filters that were kept, so it never double-counts a dropped one.
        var adjustedValueCount: Int = 0
    }

    /// Decodes a preset file's bytes.
    ///
    /// EqualizerAPO configs are edited in Notepad, so UTF-16 with a byte-order
    /// mark and Windows-1252 turn up as often as UTF-8. A leading BOM is removed
    /// whichever encoding carried it: left in, it sits in front of `Preamp:` and
    /// the line no longer parses.
    static func decodeText(_ data: Data) throws -> String {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text =
                String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
        }
        guard var text else { throw ParseError.unreadableText }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Parses text content in EqualizerAPO or `.coreeq` JSON format.
    static func parse(text: String, defaultName: String = "Imported Preset") throws -> ParsedPreset
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyContent }

        // A native .coreeq file. Nothing EqualizerAPO writes starts with a
        // brace, so one that fails to decode is a damaged file, and saying so
        // beats handing it to the text parser to report "no valid filters".
        if trimmed.starts(with: "{") {
            let profile: EQProfile
            do {
                profile = try JSONDecoder().decode(EQProfile.self, from: Data(trimmed.utf8))
            } catch {
                throw ParseError.damagedCoreEQFile
            }
            let (freeFilters, droppedFilterCount) = trimFreeFilters(
                profile.filters.filter { !$0.isBand })
            let bands = profile.filters.filter { $0.isBand }
            return ParsedPreset(
                name: profile.name.isEmpty ? defaultName : profile.name,
                preamp: profile.preamp.clamped(to: BuiltInProfiles.preampRange),
                autoGain: profile.autoGain,
                filters: FilterChain.normalized(bands + freeFilters),
                droppedFilterCount: droppedFilterCount,
                adjustedValueCount: outOfRangeCount(bands + freeFilters, preamp: profile.preamp)
            )
        }

        var preamp: Double = 0
        var sawPreampLine = false
        var rawFilters: [EQFilter] = []
        var unparsedLines: [String] = []
        var foundAnyDirective = false

        let lines = trimmed.components(separatedBy: .newlines)
        for line in lines {
            let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
            guard !lineTrimmed.isEmpty, !lineTrimmed.starts(with: "#"),
                !lineTrimmed.starts(with: ";")
            else {
                continue
            }

            if let parsedPreamp = parsePreamp(from: lineTrimmed) {
                preamp = parsedPreamp
                sawPreampLine = true
                foundAnyDirective = true
                continue
            }

            if let filter = parseFilterLine(
                from: lineTrimmed, colorIndex: rawFilters.count % EQFilter.colorCount)
            {
                rawFilters.append(filter)
                foundAnyDirective = true
            } else if isFilterDeclaration(lineTrimmed) {
                throw ParseError.unsupportedFilterDeclaration
            } else {
                // Something we do not model — `GraphicEQ:`, `Convolution:`,
                // `Channel:`, `If:` and the like. Line-level, informational, and
                // not a reason to reject the whole preset; the caller reports it.
                unparsedLines.append(lineTrimmed)
            }
        }

        // A Preamp line alone is a valid config — it is what a flat preset
        // exports as — so it is enough. Only text with neither is not a preset.
        guard foundAnyDirective else {
            throw ParseError.noValidFiltersFound
        }

        let (freeFilters, droppedFilterCount) = trimFreeFilters(rawFilters.filter { !$0.isBand })

        return ParsedPreset(
            name: defaultName,
            preamp: preamp.clamped(to: BuiltInProfiles.preampRange),
            // A Preamp line is the file choosing its own trim, so the computed
            // one starts off. Without one the file has said nothing about
            // headroom, and a boost-heavy correction would clip at 0 dB — so
            // the trim is computed, as it is for every built-in.
            autoGain: !sawPreampLine,
            // Normalising is also what clamps every value into range.
            filters: FilterChain.normalized(freeFilters),
            droppedFilterCount: droppedFilterCount,
            unparsedLines: unparsedLines,
            adjustedValueCount: outOfRangeCount(freeFilters, preamp: preamp)
        )
    }

    /// How many values `FilterChain.normalized` and the preamp clamp will
    /// change. A band only carries a gain; its frequency and Q are the ladder's.
    private static func outOfRangeCount(_ filters: [EQFilter], preamp: Double) -> Int {
        func outside(_ value: Double, _ range: ClosedRange<Double>) -> Int {
            range.contains(value) ? 0 : 1
        }
        let filterCount = filters.reduce(0) { count, filter in
            let gain = outside(filter.gain, BuiltInProfiles.gainRange)
            guard !filter.isBand else { return count + gain }
            return count + gain
                + outside(filter.frequency, BuiltInProfiles.filterFrequencyRange)
                + outside(filter.q, BuiltInProfiles.filterQRange)
        }
        return filterCount + outside(preamp, BuiltInProfiles.preampRange)
    }

    /// Keeps pass filters first up to the hard cap, then fills the remaining
    /// budget with the strongest gain-bearing filters while retaining source order.
    private static func trimFreeFilters(
        _ filters: [EQFilter]
    ) -> (
        filters: [EQFilter],
        dropped: Int
    ) {
        guard filters.count > BuiltInProfiles.maxFreeFilters else { return (filters, 0) }

        let passIndices = filters.indices.filter {
            filters[$0].kind == .highPass || filters[$0].kind == .lowPass
        }
        let keptPassIndices = Array(passIndices.prefix(BuiltInProfiles.maxFreeFilters))
        let remaining = BuiltInProfiles.maxFreeFilters - keptPassIndices.count
        let passSet = Set(passIndices)
        let gainBearingIndices = filters.indices.filter { !passSet.contains($0) }
        let strongest = gainBearingIndices.sorted {
            abs(filters[$0].gain) > abs(filters[$1].gain)
        }.prefix(remaining)
        let keptIndices = Set(keptPassIndices).union(strongest)
        let keptFilters = filters.indices.filter { keptIndices.contains($0) }.map { filters[$0] }
        return (keptFilters, filters.count - keptIndices.count)
    }

    private static func isFilterDeclaration(_ line: String) -> Bool {
        line.range(of: #"^Filter(?:\s*\d+)?\s*:"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    // MARK: - Line Parsers

    /// Parses lines such as:
    /// `Preamp: -6.4 dB`
    /// `Preamp: -6.4dB`
    /// `Preamp: 3.5`
    static func parsePreamp(from line: String) -> Double? {
        let pattern = #"^Preamp\s*:\s*([+-]?\d+(?:\.\d+)?)\s*(?:dB)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let range = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return Double(line[range])
    }

    /// Parses EqualizerAPO filter line definitions:
    /// e.g. `Filter 1: ON PK Fc 28 Hz Gain 6.2 dB Q 2.10`
    /// or `Filter: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71`
    /// or `Filter 2: ON PK Fc 1250.0 Gain -2.1 Q 1.4`
    /// or `Filter 3: ON HP Fc 20 Hz Q 0.71`
    /// or `Filter 4: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1.0`
    static func parseFilterLine(from line: String, colorIndex: Int = 0) -> EQFilter? {
        // Must start with Filter (optional index)
        guard
            line.range(
                of: #"^Filter(?:\s*\d+)?\s*:"#, options: [.regularExpression, .caseInsensitive])
                != nil
        else {
            return nil
        }

        let isEnabled: Bool
        if line.range(of: #":\s*OFF\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            isEnabled = false
        } else {
            isEnabled = true
        }

        // Determine filter kind
        let kind: EQFilter.Kind
        if line.range(of: #"\b(?:PK|PEQ|BELL)\b"#, options: [.regularExpression, .caseInsensitive])
            != nil
        {
            kind = .bell
        } else if line.range(
            of: #"\b(?:LSC|LS|LOWSHELF)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        {
            kind = .lowShelf
        } else if line.range(
            of: #"\b(?:HSC|HS|HIGHSHELF)\b"#, options: [.regularExpression, .caseInsensitive])
            != nil
        {
            kind = .highShelf
        } else if line.range(
            of: #"\b(?:HP|HPQ|HIGHPASS)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        {
            kind = .highPass
        } else if line.range(
            of: #"\b(?:LP|LPQ|LOWPASS)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        {
            kind = .lowPass
        } else {
            // Unrecognized filter kind — reject line
            return nil
        }

        // Extract Frequency (Fc ...)
        guard let frequency = extractNumber(pattern: #"\bFc\s+([0-9]+(?:\.[0-9]+)?)"#, from: line)
        else {
            return nil
        }

        // Extract Gain (Gain ... dB), defaults to 0 for high/low pass
        let gain =
            extractNumber(pattern: #"\bGain\s+([+-]?[0-9]+(?:\.[0-9]+)?)"#, from: line) ?? 0.0

        // Extract Q factor or Bandwidth (BW Oct ...)
        let q: Double
        if let directQ = extractNumber(pattern: #"\bQ\s+([0-9]+(?:\.[0-9]+)?)"#, from: line) {
            q = directQ
        } else if let bw = extractNumber(
            pattern: #"\bBW(?:\s+Oct)?\s+([0-9]+(?:\.[0-9]+)?)"#, from: line), bw > 0
        {
            // Convert bandwidth in octaves (N) to Q: Q = sqrt(2^N) / (2^N - 1)
            let pow2N = pow(2.0, bw)
            if pow2N != 1.0 {
                q = sqrt(pow2N) / (pow2N - 1.0)
            } else {
                q = BuiltInProfiles.defaultQ
            }
        } else {
            q =
                (kind == .lowShelf || kind == .highShelf)
                ? BuiltInProfiles.shelfQ : BuiltInProfiles.defaultQ
        }

        // Unclamped: `parse` counts what is out of range before
        // `FilterChain.normalized` brings it in.
        return EQFilter(
            kind: kind,
            frequency: frequency,
            gain: gain,
            q: q,
            isEnabled: isEnabled,
            band: nil,
            colorIndex: colorIndex
        )
    }

    private static func extractNumber(pattern: String, from string: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: string, range: NSRange(string.startIndex..., in: string)),
            let range = Range(match.range(at: 1), in: string)
        else {
            return nil
        }
        return Double(string[range])
    }
}

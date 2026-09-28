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
        case invalidFormat
        case noValidFiltersFound
        case unsupportedFilterDeclaration

        var errorDescription: String? {
            switch self {
            case .emptyContent:
                return "The preset content is empty."
            case .invalidFormat:
                return "The file is not a valid EqualizerAPO or CoreEQ preset."
            case .noValidFiltersFound:
                return "No valid filters were found in the preset text."
            case .unsupportedFilterDeclaration:
                return "The preset contains an unsupported filter declaration."
            }
        }
    }

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
    }

    /// Parses text content in EqualizerAPO or `.coreeq` JSON format.
    static func parse(text: String, defaultName: String = "Imported Preset") throws -> ParsedPreset
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyContent }

        // First attempt JSON decoding in case it is a native .coreeq file.
        if trimmed.starts(with: "{"),
            let data = trimmed.data(using: .utf8),
            let profile = try? JSONDecoder().decode(EQProfile.self, from: data)
        {
            let (freeFilters, droppedFilterCount) = trimFreeFilters(
                profile.filters.filter { !$0.isBand })
            let bands = profile.filters.filter { $0.isBand }
            return ParsedPreset(
                name: profile.name.isEmpty ? defaultName : profile.name,
                preamp: profile.preamp.clamped(to: BuiltInProfiles.preampRange),
                autoGain: profile.autoGain,
                filters: FilterChain.normalized(bands + freeFilters),
                droppedFilterCount: droppedFilterCount
            )
        }

        var preamp: Double = 0
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

        guard foundAnyDirective && !rawFilters.isEmpty else {
            throw ParseError.noValidFiltersFound
        }

        // Clamp preamp and normalize filters
        let clampedPreamp = preamp.clamped(to: BuiltInProfiles.preampRange)

        let (freeFilters, droppedFilterCount) = trimFreeFilters(rawFilters.filter { !$0.isBand })

        let combined = FilterChain.normalized(freeFilters)

        return ParsedPreset(
            name: defaultName,
            preamp: clampedPreamp,
            // Text presets carry their trim on the Preamp line (or 0 dB when the
            // line is absent), so the computed trim starts off in both cases.
            autoGain: false,
            filters: combined,
            droppedFilterCount: droppedFilterCount,
            unparsedLines: unparsedLines
        )
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

        let clampedFreq = frequency.clamped(to: BuiltInProfiles.filterFrequencyRange)
        let clampedGain = gain.clamped(to: BuiltInProfiles.gainRange)
        let clampedQ = q.clamped(to: BuiltInProfiles.filterQRange)

        return EQFilter(
            kind: kind,
            frequency: clampedFreq,
            gain: clampedGain,
            q: clampedQ,
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

import SwiftUI

/// The colour a parametric band is tagged with.
///
/// A band's colour is the one thing that ties its row to its node on the graph
/// once there are more than two or three of them: the row's swatch, its knobs,
/// and the node all take it, so "the purple one" is a way of pointing that
/// works in both places. It is never the *only* marker — every band also
/// carries its number — because colour alone excludes anyone who can't tell two
/// of these apart.
///
/// A fixed set rather than a free colour well. Eight named system colours stay
/// legible on both the light and the dark window, and turn choosing a colour
/// into one click instead of a trip through the system picker. They are stored
/// by index (see `EQFilter.colorIndex`), so a preset written today still opens
/// if the palette is ever extended.
///
/// All eight stay usable because `Theme.signal` is a warm neutral: a coloured
/// curve always swallowed whichever entry was its neighbour — green did it to a
/// green band, and the amber that replaced it did the same to an orange one —
/// which is why the curve gave up having a hue at all. Adding a ninth colour
/// here needs no thought about the line it will stand on.
enum BandColor: Int, CaseIterable, Identifiable {
    case green, blue, purple, pink, orange, teal, indigo, red

    var id: Int { rawValue }

    /// The palette entry for a stored index, wrapping rather than failing so a
    /// hand-edited or future preset always has a colour to draw.
    static func at(_ index: Int) -> BandColor {
        BandColor(rawValue: ((index % allCases.count) + allCases.count) % allCases.count) ?? .green
    }

    /// System colours throughout: they carry their own light and dark variants,
    /// and they are the same eight the rest of macOS labels things with.
    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .teal: return .teal
        case .indigo: return .indigo
        case .red: return .red
        }
    }

    /// Spoken and shown in the swatch's tooltip, so the choice is describable
    /// without seeing it.
    var name: String {
        switch self {
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .teal: return "Teal"
        case .indigo: return "Indigo"
        case .red: return "Red"
        }
    }
}

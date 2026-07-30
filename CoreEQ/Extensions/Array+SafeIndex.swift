import Foundation

/// Bounds-checked element access, for the places a band index and a band array
/// can briefly disagree while a preset is being switched.
extension Array {
    /// Element at `index`, or nil when it's out of bounds.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

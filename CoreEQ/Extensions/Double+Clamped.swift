import Foundation

/// Keeps a value inside a range — used wherever gains and tone values are
/// nudged by drags, arrow keys, or decoded state that may be out of date.
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

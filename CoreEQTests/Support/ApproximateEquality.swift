import Foundation

/// What `XCTAssertEqual(_:_:accuracy:)` did, in a form `#expect` can use.
///
/// Swift Testing has no accuracy overload — `#expect` takes an expression, not a
/// comparison it can loosen. Seventy-odd assertions in this suite compare
/// decibels, frequencies and filter coefficients, none of which land on exact
/// binary fractions, so the tolerance has to live somewhere. Here it reads as
/// part of the sentence:
///
/// ```swift
/// #expect(response.isClose(to: 6, within: 0.01))
/// ```
extension Double {
    /// Whether `self` and `other` agree to within `tolerance`.
    func isClose(to other: Double, within tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}

extension Float {
    func isClose(to other: Float, within tolerance: Float) -> Bool {
        abs(self - other) <= tolerance
    }
}

extension CGFloat {
    func isClose(to other: CGFloat, within tolerance: CGFloat) -> Bool {
        abs(self - other) <= tolerance
    }
}

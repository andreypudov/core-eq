import CoreGraphics
import Foundation

/// Frequency-to-x mapping for the response plot.
///
/// Pulled out of the view so the live backdrop and the static plot can share
/// one definition of where a frequency sits. Two copies would be two chances
/// for the spectrum to drift sideways from the curve it sits behind.
struct ResponseAxis: Equatable {
    /// Band centre frequencies, ascending.
    let anchors: [Double]
    /// Width reserved at the left for the dB labels.
    let gutter: CGFloat
    let width: CGFloat

    var plotWidth: CGFloat { max(width - gutter, 1) }

    /// X-axis aligned with the slider columns underneath the plot: band `i`
    /// sits at fraction `(i + 0.5) / bandCount`, and frequencies between bands
    /// interpolate logarithmically. Beyond the outermost bands the axis
    /// extrapolates using the neighbouring octave ratio.
    func fraction(of frequency: Double) -> Double {
        let n = anchors.count
        guard n >= 2, frequency > 0 else { return 0.5 }
        let slot = 1.0 / Double(n)
        func center(_ i: Int) -> Double { (Double(i) + 0.5) * slot }

        if frequency <= anchors[0] {
            return center(0) + slot * log(frequency / anchors[0]) / log(anchors[1] / anchors[0])
        }
        if frequency >= anchors[n - 1] {
            return center(n - 1) + slot * log(frequency / anchors[n - 1])
                / log(anchors[n - 1] / anchors[n - 2])
        }
        for i in 0..<(n - 1) where frequency <= anchors[i + 1] {
            return center(i) + slot * log(frequency / anchors[i]) / log(anchors[i + 1] / anchors[i])
        }
        return 1
    }

    /// Inverse of `fraction(of:)`, used to sweep the curve and to turn a pointer
    /// position into the frequency a dragged filter should take.
    func frequency(atFraction t: Double) -> Double {
        let n = anchors.count
        guard n >= 2 else { return 1_000 }
        // Position in band-index units, measured from the first band's centre.
        let position = t * Double(n) - 0.5

        if position <= 0 {
            return anchors[0] * pow(anchors[1] / anchors[0], position)
        }
        if position >= Double(n - 1) {
            return anchors[n - 1] * pow(anchors[n - 1] / anchors[n - 2], position - Double(n - 1))
        }
        let i = min(Int(position), n - 2)
        return anchors[i] * pow(anchors[i + 1] / anchors[i], position - Double(i))
    }

    func x(_ frequency: Double) -> CGFloat {
        gutter + CGFloat(min(max(fraction(of: frequency), 0), 1)) * plotWidth
    }
}

/// The analyzer backdrop, on its own layer.
///
/// This is the only part of the plot that changes at frame rate, and it is the
/// only view that observes the analyzer — so a spectrum tick invalidates this
/// and nothing else. Folded into the main canvas it took the grid's fourteen
/// text labels, the curve's biquad sweep, and the whole enclosing window's body
/// down with it, sixty times a second.

import SwiftUI

/// The eight colours a band can wear, in a popover off its swatch.
///
/// A grid of swatches rather than the system colour well: the choice is
/// "which of these eight", not "any colour", and the fixed set is what keeps
/// every band legible on both appearances and distinct from its neighbours.
struct ColorPalettePicker: View {
    let selected: Int
    let choose: (Int) -> Void

    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(BandColor.allCases) { entry in
                Button {
                    choose(entry.rawValue)
                } label: {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            // A ring rather than a tick inside the swatch: at
                            // 18 points a glyph over a saturated fill is a
                            // smudge, and the ring reads at any size.
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.9), lineWidth: 2)
                                .padding(-3)
                                .opacity(entry.rawValue == selected ? 1 : 0)
                        }
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(entry.rawValue == selected ? [.isSelected] : [])
            }
        }
        .padding(12)
    }
}

import SwiftUI

/// The CoreEQ mark, drawn as vectors rather than scaled down from the app icon.
///
/// `NSApp.applicationIconImage` is the *composed* macOS icon: the system adds a
/// bezel with a bright specular rim, and the legacy `AppIcon.icns` bakes in its
/// own rounded rect whose radius doesn't match the system mask. At sidebar size
/// both show up as pale fringes along the edges. Drawing the shapes directly is
/// crisp at any size and in either appearance.
///
/// Geometry mirrors `design/logo.svg` — the same five bars on a 1024 pt canvas,
/// expressed as fractions so it scales to whatever frame it's given.
struct AppMark: View {
    /// Brand green, matching `logo.svg` `.bg` and `AppIcon.icon`'s solid fill.
    private static let background = Color(.sRGB, red: 0.161, green: 0.675, blue: 0.286, opacity: 1)

    /// `(x, y, height)` per bar as a fraction of the canvas; all bars share a
    /// width of `barWidth`. Taken from `logo.svg` after its 1.143 centre scale.
    private static let bars: [(x: CGFloat, y: CGFloat, height: CGFloat)] = [
        (0.2299, 0.3304, 0.3349),
        (0.3527, 0.2410, 0.5023),
        (0.4755, 0.1518, 0.6921),
        (0.5982, 0.2410, 0.5023),
        (0.7210, 0.3304, 0.3349),
    ]
    private static let barWidth: CGFloat = 0.0781
    private static let barCornerRadius: CGFloat = 0.0179
    private static let backgroundCornerRadius: CGFloat = 0.2236

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(
                    cornerRadius: side * Self.backgroundCornerRadius, style: .continuous
                )
                .fill(Self.background)

                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: side * Self.barCornerRadius, style: .continuous)
                        .fill(.white)
                        .frame(width: side * Self.barWidth, height: side * bar.height)
                        .offset(x: side * bar.x, y: side * bar.y)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

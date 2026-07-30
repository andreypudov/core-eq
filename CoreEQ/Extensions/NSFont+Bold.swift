import AppKit

/// Bold variants for the AppKit menu views, which style their own labels
/// instead of getting a font from SwiftUI.
extension NSFont {
    /// Bold companion of the receiver, falling back to the original if the
    /// bold variant is unavailable.
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}

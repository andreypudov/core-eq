import Foundation

/// Sizes shared by every custom view in the status-bar `NSMenu`.
///
/// Everything the menu can express with a plain `NSMenuItem` (rows, separators,
/// section headers) is left to `MenuBarController`, so it renders in the real
/// system menu font and behaves like the Wi‑Fi / Sound menus. The pieces AppKit
/// menus can't express — the header on/off switch, the live response graph, the
/// tone sliders, and the two inline choosers — are `NSView`s, and they all size
/// themselves against the numbers here so the menu has one content width.
enum QuickEQMenuMetrics {
    /// Width of the custom content, chosen to sit comfortably next to the
    /// standard menu rows. The menu sizes itself to its widest item.
    static let contentWidth: CGFloat = 300
    /// Leading/trailing inset that lines the custom content up with the text of
    /// standard menu items.
    static let horizontalInset: CGFloat = 14
    static let graphHeight: CGFloat = 60
}

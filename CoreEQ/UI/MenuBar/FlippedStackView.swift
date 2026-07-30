import AppKit

/// Document view of the list's scroll view. Flipped so the rows start at the top
/// and the first option is what you see, rather than the last.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

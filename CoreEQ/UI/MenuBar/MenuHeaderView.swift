import AppKit

/// Header row: a bold "CoreEQ" title on the left and a native `NSSwitch` on the
/// right, matching the Wi‑Fi menu's title-plus-toggle header. No icon.
@MainActor
final class MenuHeaderView: NSView {
    private let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        // View-based menu items are sized by Auto Layout, so drive the whole
        // view from constraints (fixed content width, fixed row height).
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "CoreEQ")
        title.font = NSFont.menuFont(ofSize: 0).bold()
        title.translatesAutoresizingMaskIntoConstraints = false

        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(switchToggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityLabel("CoreEQ equalizer")

        addSubview(title)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: QuickEQMenuMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: QuickEQMenuMetrics.horizontalInset),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -QuickEQMenuMetrics.horizontalInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func switchToggled() {
        onToggle(toggle.state == .on)
    }
}

import AppKit

/// One row of the menu: an optional leading image, a title, and an optional
/// trailing chevron. Highlights under the pointer and runs `onClick` when
/// released, exactly like a standard menu item — but as a plain view, so a whole
/// list of them can live inside a single menu item.
@MainActor
final class MenuRowView: NSView {
    /// What sits at the trailing edge of the row.
    enum Accessory {
        /// Nothing — an option row, or a value with nothing to choose from.
        case none
        /// A chevron: `>` while the list is folded, `v` while it is open below.
        case disclosure(expanded: Bool)
    }

    private let highlight = NSVisualEffectView()
    private let titleLabel: NSTextField
    private let iconView = NSImageView()
    private let chevronView = NSImageView()
    private let onClick: () -> Void

    /// Set when the row lives inside a list. The list then owns the highlight
    /// for all of its rows: a row that scrolls out from under the pointer never
    /// receives `mouseExited`, so a row deciding its own highlight would stay
    /// lit and a fast scroll would leave a trail of them.
    weak var listOwner: MenuListView?

    private var accessory: Accessory
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            highlight.isHidden = !isHighlighted
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            chevronView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        }
    }

    /// Lets the owning list drive the highlight from the pointer's real
    /// position rather than from enter / exit events that may never arrive.
    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
    }

    /// - Parameters:
    ///   - image: drawn in the leading gutter — a device badge, or nothing.
    ///   - gutter: width of that leading gutter; zero for a text-only row.
    init(
        title: String,
        image: NSImage? = nil,
        gutter: CGFloat = 0,
        height: CGFloat,
        accessory: Accessory = .none,
        onClick: @escaping () -> Void
    ) {
        self.accessory = accessory
        self.onClick = onClick
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.material = .selection
        highlight.blendingMode = .behindWindow
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = MenuListMetrics.highlightCornerRadius
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = image
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        chevronView.contentTintColor = .secondaryLabelColor
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(chevronView)

        let inset = QuickEQMenuMetrics.horizontalInset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: QuickEQMenuMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: height),

            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuListMetrics.highlightInset),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuListMetrics.highlightInset),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconView.widthAnchor.constraint(equalToConstant: max(gutter - 4, 0)),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + gutter),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronView.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        applyAccessory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Flips the chevron between `>` and `v` without rebuilding the menu, so the
    /// row can answer a click while the menu stays open.
    func setExpanded(_ expanded: Bool) {
        guard case .disclosure = accessory else { return }
        accessory = .disclosure(expanded: expanded)
        applyAccessory()
    }

    private func applyAccessory() {
        switch accessory {
        case .none:
            chevronView.image = nil
        case .disclosure(let expanded):
            let symbol = NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.forward",
                accessibilityDescription: nil
            )
            chevronView.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            )
            setAccessibilityValue(expanded ? "expanded" : "collapsed")
        }
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        if let listOwner {
            listOwner.updateHighlightUnderPointer()
        } else {
            isHighlighted = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let listOwner {
            listOwner.updateHighlightUnderPointer()
        } else {
            isHighlighted = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallowed so the menu's own tracking doesn't treat the press as a
        // click-through on the item behind the view.
        if let listOwner {
            listOwner.updateHighlightUnderPointer()
        } else {
            isHighlighted = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

import AppKit

/// Inline choosers for the status-bar menu, in the spirit of the system Wi‑Fi
/// network list: a row names the current value and carries a `>`, and clicking
/// it turns that into a `v` and unfolds the *other* options directly below,
/// inside the same menu rather than in a submenu. The value row stays where it
/// is, so clicking it again folds the list away. A list longer than
/// `MenuListMetrics.maxVisibleRows` scrolls instead of stretching the menu down
/// the screen.
///
/// The open list never repeats the value row's own entry: what is showing above
/// it is the current choice, and everything below is what else there is.
///
/// AppKit has no such control, so every row here is an `NSView` inside a
/// view-based `NSMenuItem`: `MenuRowView` draws one row (highlight, click,
/// chevron) and `MenuListView` stacks the option rows in a scroll view.
/// `MenuBarController` owns which section is open and inserts the list under the
/// row on the live menu.
enum MenuListMetrics {
    /// Height of a row that is only text.
    static let rowHeight: CGFloat = 24
    /// Height of a row carrying a 28 pt device badge.
    static let deviceRowHeight: CGFloat = 34

    /// Leading gutter for the circular badge of a device row. Titles start after
    /// it, so the collapsed row and the options it opens share one text margin.
    /// Preset rows have no gutter — nothing marks the active one, so there is
    /// nothing to reserve room for.
    static let badgeGutter: CGFloat = 32

    /// How much of the list is on screen before it starts scrolling. The half
    /// row is deliberate: a row cut in two is what tells you there is more.
    static let maxVisibleRows: CGFloat = 5.5

    /// Inset of the highlight from the menu's edges, matching the rounded
    /// selection AppKit draws for standard rows.
    static let highlightInset: CGFloat = 6
    static let highlightCornerRadius: CGFloat = 5
}

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

/// The unfolded list: option rows stacked in a scroll view that stops growing
/// after `MenuListMetrics.maxVisibleRows`. Lives in one view-based menu item, so
/// expanding a section is a single insertion into the open menu. Always opens at
/// the top: the current choice is the row above, never one of these.
@MainActor
final class MenuListView: NSView {
    private let scroll = NSScrollView()
    private let rows: [MenuRowView]
    private let visibleHeight: CGFloat

    init(rows: [MenuRowView], rowHeight: CGFloat) {
        self.rows = rows
        self.visibleHeight = (rowHeight * min(CGFloat(rows.count), MenuListMetrics.maxVisibleRows)).rounded()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { $0.listOwner = self }

        let stack = FlippedStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: QuickEQMenuMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: visibleHeight),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Pinned at the top and left with a free bottom: the stack's own
            // height drives the scrollable extent.
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // Rows sliding under a still pointer change which one is hovered without
        // any mouse event to say so, so the highlight is recomputed on every
        // scroll as well.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clipViewDidScroll() {
        updateHighlightUnderPointer()
    }

    /// Lights the one row the pointer is actually over and clears every other,
    /// from the pointer's live position rather than from enter / exit events.
    /// This is the only thing that sets a list row's highlight, so no scroll —
    /// however fast — can leave more than one row lit.
    func updateHighlightUnderPointer() {
        guard let window else {
            rows.forEach { $0.setHighlighted(false) }
            return
        }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        for row in rows {
            let inRow = row.convert(inWindow, from: nil)
            // Both tests matter: `bounds` finds the row under the pointer, and
            // `visibleRect` rejects the ones scrolled out past the clip.
            row.setHighlighted(row.bounds.contains(inRow) && row.visibleRect.contains(inRow))
        }
    }

}

/// Document view of the list's scroll view. Flipped so the rows start at the top
/// and the first option is what you see, rather than the last.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

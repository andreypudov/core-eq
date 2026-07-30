import AppKit

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

import SwiftUI

/// The Parametric tab: where free filters are created and edited.
///
/// Empty by default, and reached only by choosing the tab, so someone who wants
/// the eleven sliders never meets it. Once they are here the vocabulary is the
/// standard one — Bell, Low Shelf, Q — because choosing the tab is opting in,
/// and renaming Q to something friendlier would not help the person who does
/// not want it while making the person who does guess what it means.
///
/// Laid out as a table rather than a list of rows: six parameters across
/// several bands is a grid of values, and a grid is read down a column. The
/// column titles are pinned at the top of the list, so they stay put while the
/// bands scroll under them.
struct FilterListView: View {
    @ObservedObject var profileManager: ProfileManager
    let isEnabled: Bool
    /// The filter whose node is highlighted on the graph, kept in step with the
    /// row selection so pointing at one points at both.
    @Binding var selectedFilterID: UUID?

    var body: some View {
        // The table takes every point the block has, and Add Band sits on the
        // bottom edge under it. Before, the list stopped at three rows and the
        // leftover height sat empty below the section — so a fourth band had to
        // be scrolled to while the space to show it was right there.
        VStack(alignment: .leading, spacing: 0) {
            // No header: the tab on the block's border names this editor, and
            // the switch for it sits on the same border.
            content
                .frame(maxHeight: .infinity, alignment: .top)
            addRow
        }
        .opacity(isEnabled ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.18), value: profileManager.freeFilters.count)
    }

    private var hasBands: Bool { !profileManager.freeFilters.isEmpty }

    /// The column titles. Same widths and same spacing as a band row, from the
    /// same tokens, so the two can't drift apart.
    private var columnTitles: some View {
        HStack(spacing: 0) {
            title("#", width: Theme.FilterRow.Column.index, alignment: .leading)
            ColumnGap()
            title("Enable", width: Theme.FilterRow.Column.enable)
            ColumnGap()
            title("Type", width: Theme.FilterRow.Column.type)
            ColumnGap()
            title("Frequency", width: Theme.FilterRow.Column.frequency)
            ColumnGap()
            title("Gain", width: Theme.FilterRow.Column.gain)
            ColumnGap()
            title("Q", width: Theme.FilterRow.Column.q)
            Spacer(minLength: Theme.FilterRow.columnSpacing)
            title("Actions", width: Theme.FilterRow.Column.actions, alignment: .trailing)
        }
        .frame(height: Theme.FilterRow.headerHeight)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }

    /// A title sits over its column at the column's own width, but keeps its
    /// full length if it is the wider of the two: the columns are sized for the
    /// controls in them, and "Actions" over a 24-point button would otherwise
    /// arrive as "Ac…".
    private func title(_ text: String, width: CGFloat, alignment: Alignment = .center) -> some View
    {
        Text(text)
            // The size the Preamp readout and the band captions use, so the
            // window has one voice for the small print rather than a different
            // one per section.
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .fixedSize()
            .frame(width: width, alignment: alignment)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !profileManager.freeFilters.isEmpty {
                Rectangle()
                    .fill(Theme.blockBorder)
                    .frame(height: 1)
            }

            Button {
                addFilter()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add Band")
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(profileManager.canAddFilter ? Color.accentColor : Color.secondary)
            .disabled(!isEnabled || !profileManager.canAddFilter)
            .padding(.top, 8)
            .padding(.leading, 8)
            .help(
                profileManager.canAddFilter
                    ? "Add a parametric band"
                    : "CoreEQ holds up to \(BuiltInProfiles.maxFreeFilters) parametric bands"
            )
        }
    }

    // MARK: - Content

    /// The list scrolls inside whatever height the editing area has, rather
    /// than growing the section.
    ///
    /// Without the bound the column's intrinsic height grows with every band
    /// added, and because the window sizes itself from its content, a full list
    /// pushes the window taller than the screen. The graph is the element that
    /// deserves the leftover height; this one gets the editing area's fixed
    /// height and a scrollbar — but all of it, so nothing has to be scrolled to
    /// while empty space sits below the section.
    @ViewBuilder
    private var content: some View {
        if profileManager.freeFilters.isEmpty {
            emptyState
        } else {
            // The titles live *inside* the scroll view, pinned. Above it they
            // would be laid out in the block's full width while the rows are
            // laid out in what the scroll bar leaves — and on a Mac with a
            // mouse plugged in, that is fifteen points of drift between every
            // title and the column under it.
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(
                                    Array(profileManager.freeFilters.enumerated()), id: \.element.id
                                ) { index, filter in
                                    FilterRowView(
                                        index: index + 1,
                                        filter: filter,
                                        isSelected: selectedFilterID == filter.id,
                                        isEnabled: isEnabled,
                                        profileManager: profileManager
                                    )
                                    .onTapGesture { selectedFilterID = filter.id }

                                    if filter.id != profileManager.freeFilters.last?.id {
                                        Rectangle()
                                            .fill(Theme.blockBorder)
                                            .frame(height: Theme.FilterRow.separator)
                                            .padding(.leading, 8)
                                    }
                                }
                            } header: {
                                // The window's own material, so rows pass behind the
                                // titles instead of through them, and the strip still
                                // reads as part of the one canvas.
                                columnTitles.background(WindowBackground())
                            }
                        }
                    }
                    // A whole number of rows, never a sliced one. The leftover is
                    // at most a row's height and sits below the table as padding,
                    // where it reads as space rather than as a band cut in half.
                    .frame(height: visibleHeight(in: geometry.size.height))
                    .scrollBounceBehavior(.basedOnSize)
                    // Only a few rows are visible at a time, so a band chosen by
                    // clicking its node on the graph is often one the table isn't
                    // showing. Bringing it into view is what makes the two halves
                    // of the selection one thing rather than two.
                    .onChange(of: selectedFilterID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// The tallest whole number of rows that fits in `available`, plus the
    /// pinned title row above them.
    ///
    /// A row and the hairline under it are one pitch; the last row has no
    /// hairline, hence the odd point back. Never less than one row, so a very
    /// short window shows a band rather than a sliver of one.
    private func visibleHeight(in available: CGFloat) -> CGFloat {
        let pitch = Theme.FilterRow.height + Theme.FilterRow.separator
        let forRows = available - Theme.FilterRow.headerHeight
        let rows = max(1, ((forRows + Theme.FilterRow.separator) / pitch).rounded(.down))
        return min(
            rows * pitch - Theme.FilterRow.separator + Theme.FilterRow.headerHeight, available)
    }

    /// Says what a band is for and how to make one, and stops.
    ///
    /// Two short lines rather than a paragraph explaining the architecture:
    /// someone who has chosen this tab knows what a filter is, and someone who
    /// hasn't is not reading an empty box.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No bands yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(
                "A band boosts or cuts one frequency, on top of the Graphic sliders. Add one below, or double-click the graph where you want it."
            )
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func addFilter() {
        // 1 kHz at 0 dB: audible to nobody until the user moves it, so adding a
        // filter never changes the sound by itself.
        if let id = profileManager.addFilter() {
            selectedFilterID = id
        }
    }

}

/// One band: its colour and number, a switch, a kind menu, and three knobs each
/// with the number it is holding.
///
/// Knob *and* number, not one or the other. The knob is how a value is found
/// while listening — dragged, scrolled, nudged until it sounds right — and the
/// number is how a value already known is entered. The graph is the third way
/// in, and all three write to the same filter.

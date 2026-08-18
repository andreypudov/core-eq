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
    private func title(_ text: String, width: CGFloat, alignment: Alignment = .center) -> some View {
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
                            ForEach(Array(profileManager.freeFilters.enumerated()), id: \.element.id) { index, filter in
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
        return min(rows * pitch - Theme.FilterRow.separator + Theme.FilterRow.headerHeight, available)
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

            Text("A band boosts or cuts one frequency, on top of the Graphic sliders. Add one below, or double-click the graph where you want it.")
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
/// The space between two columns, in the title row and in every band row — one
/// definition, because a gap that differed between them would put every title
/// off its column by the difference, multiplied along the row.
///
/// Flexible rather than fixed: the columns are sized for their controls, so a
/// window wider than the minimum has width left over, and sharing it between
/// the gaps is what keeps the table from sitting bunched against its left edge.
private struct ColumnGap: View {
    var body: some View {
        Spacer(minLength: Theme.FilterRow.columnSpacing)
            .frame(maxWidth: Theme.FilterRow.columnSpacingMax)
    }
}

struct FilterRowView: View {
    let index: Int
    let filter: EQFilter
    let isSelected: Bool
    let isEnabled: Bool
    @ObservedObject var profileManager: ProfileManager

    @State private var isChoosingColor = false

    private var color: Color { BandColor.at(filter.colorIndex).color }

    /// Whether this band is reaching the audio. The values it holds dim when it
    /// isn't, so a band that is switched off reads as switched off without
    /// leaving the table.
    private var isLive: Bool { isEnabled && filter.isEnabled }

    var body: some View {
        HStack(spacing: 0) {
            indexCell
            ColumnGap()
            enableCell
            ColumnGap()
            typeCell
            ColumnGap()
            frequencyCell
            ColumnGap()
            gainCell
            ColumnGap()
            qCell
            // Uncapped, unlike the gaps between the values: whatever is left
            // after they reach their ceiling collects here, which is what keeps
            // the delete button on the right edge of the row instead of
            // drifting inward as the window widens.
            Spacer(minLength: Theme.FilterRow.columnSpacing)
            actionsCell
        }
        .frame(height: Theme.FilterRow.height)
        .padding(.horizontal, 8)
        // A neutral wash, with the band's colour only in the outline.
        //
        // A coloured fill behind the row tints every control standing on it —
        // the fields are translucent, so their text lost contrast and the whole
        // row read as dimmed, as though selecting it had switched it off. The
        // colour still belongs here, saying which node on the graph this row
        // is, but it belongs at the edge of the row rather than under the
        // values.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.06 : 0.0))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color.opacity(isSelected ? 0.7 : 0.0), lineWidth: 1.5)
                )
        )
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset Gain") { profileManager.resetFilter(id: filter.id) }
            Divider()
            Button("Remove Band", role: .destructive) { profileManager.removeFilter(id: filter.id) }
        }
    }

    // MARK: - Cells

    /// The swatch is a button, and the number beside it never changes colour:
    /// the colour is a second way to tell bands apart, never the only one.
    private var indexCell: some View {
        HStack(spacing: Theme.FilterRow.Column.indexGap) {
            Button {
                isChoosingColor = true
            } label: {
                Circle()
                    .fill(color.opacity(isLive ? 1.0 : 0.35))
                    .frame(width: 8, height: 8)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help("Change this band's colour")
            .accessibilityLabel("Band \(index) colour, \(BandColor.at(filter.colorIndex).name)")
            .popover(isPresented: $isChoosingColor, arrowEdge: .bottom) {
                ColorPalettePicker(selected: filter.colorIndex) { choice in
                    profileManager.setFilterColor(choice, id: filter.id)
                    isChoosingColor = false
                }
            }

            Text("\(index)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                // A band number is two glyphs at most and must stay on one line.
                // Given the room to sit on one it will, but wrapping is the one
                // outcome that has to be impossible: it breaks the row's fixed
                // height rather than just looking cramped.
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: Theme.FilterRow.Column.index, alignment: .leading)
    }

    private var enableCell: some View {
        Toggle("", isOn: enabledBinding)
            .toggleStyle(.bandPower)
            .labelsHidden()
            .disabled(!isEnabled)
            .accessibilityLabel("Band \(index) enabled")
            .frame(width: Theme.FilterRow.Column.enable)
    }

    private var typeCell: some View {
        Picker("", selection: kindBinding) {
            ForEach(EQFilter.Kind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .disabled(!isEnabled)
        .accessibilityLabel("Band \(index) type")
        .frame(width: Theme.FilterRow.Column.type)
    }

    private var frequencyCell: some View {
        parameterCell(
            width: Theme.FilterRow.Column.frequency,
            scale: .filterFrequency,
            value: \.frequency,
            unit: "Hz",
            // No thousands separator: this is a frequency, and "8,000 Hz" is
            // not how anyone writes one.
            format: .number.precision(.fractionLength(0)).grouping(.never),
            label: "Band \(index) frequency",
            help: "Drag or scroll to set; double-click the knob to return to 1 kHz",
            reset: { profileManager.setFilterFrequency(1_000, id: filter.id) },
            commit: { profileManager.setFilterFrequency($0, id: filter.id) }
        )
    }

    @ViewBuilder
    private var gainCell: some View {
        if filter.kind.usesGain {
            parameterCell(
                width: Theme.FilterRow.Column.gain,
                scale: .filterGain,
                value: \.gain,
                unit: "dB",
                format: .number.precision(.fractionLength(1))
                    .sign(strategy: .always(includingZero: false)),
                // Gain is the one parameter with a meaningful centre, so its arc
                // grows out of the middle the way the sliders' fill does.
                isBipolar: true,
                label: "Band \(index) gain",
                help: "Drag or scroll to set; double-click the knob to return to 0 dB",
                reset: { profileManager.resetFilter(id: filter.id) },
                commit: { profileManager.setFilterGain($0, id: filter.id) }
            )
        } else {
            // High and low pass cut by slope alone, so there is no gain to show
            // and nothing is greyed out in its place.
            Color.clear
                .frame(width: Theme.FilterRow.Column.gain, height: 1)
        }
    }

    private var qCell: some View {
        parameterCell(
            width: Theme.FilterRow.Column.q,
            scale: .filterQ,
            value: \.q,
            unit: nil,
            format: .number.precision(.fractionLength(2)),
            label: "Band \(index) Q",
            help: "Drag or scroll to set; double-click the knob to return to the default width",
            reset: { profileManager.setFilterQ(BuiltInProfiles.defaultQ, id: filter.id) },
            commit: { profileManager.setFilterQ($0, id: filter.id) }
        )
    }

    /// No power button here. The Enable switch is already this band's on/off,
    /// and two controls for one state is two places to look for it.
    private var actionsCell: some View {
        Button {
            profileManager.removeFilter(id: filter.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!isEnabled)
        .help("Remove this band")
        .accessibilityLabel("Remove band \(index)")
        .frame(width: Theme.FilterRow.Column.actions)
    }

    /// One parameter: a knob and the number it is holding, sized to the column
    /// they share.
    ///
    /// Both are built from a single `KnobScale`, so the two halves of a cell
    /// cannot disagree about the parameter's range, its detents, or what values
    /// it may land on — including under a scroll, which either half answers.
    ///
    /// Both dim while the band is switched off. They still work, because
    /// dialling a band in before letting it through is a reasonable way to
    /// work, but they are not describing anything anyone is hearing.
    private func parameterCell(
        width: CGFloat,
        scale: KnobScale,
        value: KeyPath<EQFilter, Double>,
        unit: String?,
        format: FloatingPointFormatStyle<Double>,
        isBipolar: Bool = false,
        label: String,
        help: String,
        reset: @escaping () -> Void,
        commit: @escaping (Double) -> Void
    ) -> some View {
        let binding = live(value, commit: commit)

        return HStack(spacing: 6) {
            KnobControl(
                value: binding,
                scale: scale,
                tint: color,
                isEnabled: isEnabled,
                isBipolar: isBipolar,
                onReset: reset
            )
            .frame(width: Theme.FilterRow.knobDiameter, height: Theme.FilterRow.knobDiameter)
            .accessibilityLabel(label)
            .help(help)

            ValueField(
                value: binding,
                unit: unit,
                format: format,
                scale: scale,
                isEnabled: isEnabled,
                accessibilityLabel: label
            )
            .help(help)
        }
        .opacity(isLive ? 1.0 : 0.55)
        .frame(width: width)
    }

    /// A binding that reads the parameter from the chain at the moment it is
    /// asked, rather than from the copy this row was built with.
    ///
    /// Scroll events arrive faster than SwiftUI rebuilds the row — a single
    /// flick delivers several inside one frame. Reading the captured copy would
    /// step all of them from the same starting value, so a flick of five would
    /// move one detent, and a scroll back the other way would land a detent
    /// short of where it began. That is exactly the drift this pass set out to
    /// remove; the ladder alone does not fix it.
    private func live(
        _ parameter: KeyPath<EQFilter, Double>,
        commit: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: {
                profileManager.freeFilters.first { $0.id == filter.id }?[keyPath: parameter]
                    ?? filter[keyPath: parameter]
            },
            set: commit
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { filter.isEnabled },
            set: { profileManager.setFilterEnabled($0, id: filter.id) }
        )
    }

    private var kindBinding: Binding<EQFilter.Kind> {
        Binding(
            get: { filter.kind },
            set: { profileManager.setFilterKind($0, id: filter.id) }
        )
    }
}

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

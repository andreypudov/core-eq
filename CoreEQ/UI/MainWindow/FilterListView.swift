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
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .padding(.top, 8)
            addRow
            Spacer(minLength: 0)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.18), value: profileManager.freeFilters.count)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Parametric Bands")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            // The same switch the Graphic tab has over its sliders: hearing one
            // half of the chain on its own is what teaches that both halves feed
            // the one curve above.
            Toggle("", isOn: freeFiltersEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!isEnabled || profileManager.freeFilters.isEmpty)
                .help("Switch every parametric band off to hear the band levels on their own")
        }
    }

    private var summary: String {
        let count = profileManager.freeFilters.count
        switch count {
        case 0: return "None"
        case 1: return "1 band"
        default: return "\(count) bands"
        }
    }

    /// The column titles. Same widths and same spacing as a band row, from the
    /// same tokens, so the two can't drift apart.
    private var columnTitles: some View {
        HStack(spacing: Theme.FilterRow.columnSpacing) {
            title("#", width: Theme.FilterRow.Column.index, alignment: .leading)
            title("Enable", width: Theme.FilterRow.Column.enable)
            title("Type", width: Theme.FilterRow.Column.type)
            title("Frequency", width: Theme.FilterRow.Column.frequency)
            title("Gain", width: Theme.FilterRow.Column.gain)
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
            .font(.system(size: 10, weight: .medium))
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
            .foregroundStyle(profileManager.canAddFilter ? Color.coreEQAccent : Color.secondary)
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

    /// The list scrolls inside a fixed height rather than growing the section.
    ///
    /// Without the cap the column's intrinsic height grows with every filter
    /// added, and because the window sizes itself from its content, a full list
    /// pushes the window taller than the screen. The graph is the element that
    /// deserves the leftover height; this one gets a bounded box and a
    /// scrollbar.
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
                                    .frame(height: 1)
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
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Grows with the list up to three rows, then stops and scrolls — so one
    /// filter doesn't reserve the space of eight, and eight don't take over the
    /// window. The pinned title row is inside this box, so its height is part
    /// of the sum.
    private var listHeight: CGFloat {
        let rows = min(profileManager.freeFilters.count, 3)
        return CGFloat(rows) * Theme.FilterRow.height + Theme.FilterRow.headerHeight + 4
    }

    /// The moment the mental model is either formed or lost, so it states the
    /// relationship rather than leaving the user to infer it from an empty box.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parametric bands add to the band levels in the Graphic tab. Both are part of one equalizer, and the graph always shows the result.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Add one below, or double-click the graph where you want it.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
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

    private var freeFiltersEnabled: Binding<Bool> {
        Binding(
            get: { profileManager.areFreeFiltersEnabled },
            set: { profileManager.setFreeFiltersEnabled($0) }
        )
    }
}

/// One band: its colour and number, a switch, a kind menu, and three knobs each
/// with the number it is holding.
///
/// Knob *and* number, not one or the other. The knob is how a value is found
/// while listening — dragged, scrolled, nudged until it sounds right — and the
/// number is how a value already known is entered. The graph is the third way
/// in, and all three write to the same filter.
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
        HStack(spacing: Theme.FilterRow.columnSpacing) {
            indexCell
            enableCell
            typeCell
            frequencyCell
            gainCell
            qCell
            Spacer(minLength: Theme.FilterRow.columnSpacing)
            actionsCell
        }
        .frame(height: Theme.FilterRow.height)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.07 : 0.0))
        )
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
        HStack(spacing: 6) {
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
        }
        .frame(width: Theme.FilterRow.Column.index, alignment: .leading)
    }

    private var enableCell: some View {
        Toggle("", isOn: enabledBinding)
            .toggleStyle(.switch)
            .controlSize(.mini)
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
        parameterCell(width: Theme.FilterRow.Column.frequency) {
            KnobControl(
                value: Binding(
                    get: { filter.frequency },
                    set: { profileManager.setFilterFrequency($0, id: filter.id) }
                ),
                scale: .frequency(BuiltInProfiles.filterFrequencyRange),
                tint: color,
                isEnabled: isEnabled,
                onReset: { profileManager.setFilterFrequency(1_000, id: filter.id) }
            )
            .accessibilityLabel("Band \(index) frequency")
            .help("Drag, scroll, or double-click to return to 1 kHz")
        } field: {
            ValueField(
                value: filter.frequency,
                unit: "Hz",
                // No thousands separator: this is a frequency, and "8,000 Hz"
                // is not how anyone writes one.
                format: .number.precision(.fractionLength(0)).grouping(.never),
                isEnabled: isEnabled,
                accessibilityLabel: "Band \(index) frequency"
            ) { profileManager.setFilterFrequency($0, id: filter.id) }
        }
    }

    @ViewBuilder
    private var gainCell: some View {
        if filter.kind.usesGain {
            parameterCell(width: Theme.FilterRow.Column.gain) {
                KnobControl(
                    value: Binding(
                        get: { filter.gain },
                        set: { profileManager.setFilterGain($0, id: filter.id) }
                    ),
                    scale: .linear(BuiltInProfiles.gainRange, step: 0.5),
                    tint: color,
                    isEnabled: isEnabled,
                    // Gain is the one parameter with a meaningful centre, so its
                    // arc grows out of the middle the way the sliders' fill does.
                    isBipolar: true,
                    onReset: { profileManager.resetFilter(id: filter.id) }
                )
                .accessibilityLabel("Band \(index) gain")
                .help("Drag, scroll, or double-click to return to 0 dB")
            } field: {
                ValueField(
                    value: filter.gain,
                    unit: "dB",
                    format: .number.precision(.fractionLength(1))
                        .sign(strategy: .always(includingZero: false)),
                    isEnabled: isEnabled,
                    accessibilityLabel: "Band \(index) gain"
                ) { profileManager.setFilterGain($0, id: filter.id) }
            }
        } else {
            // High and low pass cut by slope alone, so there is no gain to show
            // and nothing is greyed out in its place.
            Color.clear
                .frame(width: Theme.FilterRow.Column.gain, height: 1)
        }
    }

    private var qCell: some View {
        parameterCell(width: Theme.FilterRow.Column.q) {
            KnobControl(
                value: Binding(
                    get: { filter.q },
                    set: { profileManager.setFilterQ($0, id: filter.id) }
                ),
                scale: .q(BuiltInProfiles.filterQRange),
                tint: color,
                isEnabled: isEnabled,
                onReset: { profileManager.setFilterQ(BuiltInProfiles.defaultQ, id: filter.id) }
            )
            .accessibilityLabel("Band \(index) Q")
            .help("Drag, scroll, or double-click to return to the default width")
        } field: {
            ValueField(
                value: filter.q,
                unit: nil,
                format: .number.precision(.fractionLength(2)),
                isEnabled: isEnabled,
                accessibilityLabel: "Band \(index) Q"
            ) { profileManager.setFilterQ($0, id: filter.id) }
        }
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

    /// A knob and its number, sized to the column they share.
    ///
    /// Both dim while the band is switched off — they still work, because
    /// dialling a band in before letting it through is a reasonable way to
    /// work, but they are not describing anything anyone is hearing.
    private func parameterCell<Knob: View, Field: View>(
        width: CGFloat,
        @ViewBuilder knob: () -> Knob,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 6) {
            knob()
                .frame(width: Theme.FilterRow.knobDiameter, height: Theme.FilterRow.knobDiameter)
            field()
        }
        .opacity(isLive ? 1.0 : 0.55)
        .frame(width: width)
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

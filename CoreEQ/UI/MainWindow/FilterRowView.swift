import SwiftUI


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

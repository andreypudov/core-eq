import SwiftUI

/// The Parametric tab: where free filters are created and edited numerically.
///
/// Empty by default, and reached only by choosing the tab, so someone who wants
/// the eleven sliders never meets it. Once they are here the vocabulary is the
/// standard one — Bell, Low Shelf, Q — because choosing the tab is opting in,
/// and renaming Q to something friendlier would not help the person who does not
/// want it while making the person who does guess what it means.
struct FilterListView: View {
    @ObservedObject var profileManager: ProfileManager
    let isEnabled: Bool
    /// The filter whose node is highlighted on the graph, kept in step with the
    /// row selection so pointing at one points at both.
    @Binding var selectedFilterID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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

    private var addRow: some View {
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
        .padding(.top, 6)
        .padding(.leading, 8)
        .help(
            profileManager.canAddFilter
                ? "Add a parametric band"
                : "CoreEQ holds up to \(BuiltInProfiles.maxFreeFilters) parametric bands"
        )
    }

    private var summary: String {
        let count = profileManager.freeFilters.count
        switch count {
        case 0: return "None"
        case 1: return "1 band"
        default: return "\(count) bands"
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
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(profileManager.freeFilters.enumerated()), id: \.element.id) { index, filter in
                        FilterRowView(
                            index: index + 1,
                            filter: filter,
                            isSelected: selectedFilterID == filter.id,
                            isEnabled: isEnabled,
                            profileManager: profileManager
                        )
                        .onTapGesture { selectedFilterID = filter.id }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Grows with the list up to three rows, then stops and scrolls — so one
    /// filter doesn't reserve the space of eight, and eight don't take over the
    /// window.
    private var listHeight: CGFloat {
        let rows = min(profileManager.freeFilters.count, 3)
        return CGFloat(rows) * Theme.FilterRow.height + 8
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

/// One filter: a kind menu and three numeric fields.
///
/// Numeric rather than draggable on purpose. The graph is where a filter is
/// dialled in by feel; this is where it is set exactly, and one of the two has
/// to be the precise one.
struct FilterRowView: View {
    let index: Int
    let filter: EQFilter
    let isSelected: Bool
    let isEnabled: Bool
    @ObservedObject var profileManager: ProfileManager

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!isEnabled)
                .accessibilityLabel("Filter \(index) enabled")

            Text("\(index)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .trailing)

            Picker("", selection: kindBinding) {
                ForEach(EQFilter.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 116)
            .accessibilityLabel("Filter \(index) type")

            numericField(
                value: filter.frequency,
                unit: "Hz",
                width: 62,
                format: filter.frequency >= 1_000 ? "%.0f" : "%.0f",
                accessibility: "Filter \(index) frequency"
            ) { profileManager.setFilterFrequency($0, id: filter.id) }

            if filter.kind.usesGain {
                numericField(
                    value: filter.gain,
                    unit: "dB",
                    width: 58,
                    format: "%.1f",
                    accessibility: "Filter \(index) gain"
                ) { profileManager.setFilterGain($0, id: filter.id) }
            } else {
                // High and low pass cut by slope alone, so there is no gain to
                // show and nothing is greyed out in its place.
                Color.clear.frame(width: 58, height: 1)
            }

            numericField(
                value: filter.q,
                unit: "Q",
                width: 54,
                format: "%.2f",
                unitLeading: true,
                accessibility: "Filter \(index) Q"
            ) { profileManager.setFilterQ($0, id: filter.id) }

            Spacer(minLength: 0)

            Button {
                profileManager.removeFilter(id: filter.id)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("Remove this filter")
            .accessibilityLabel("Remove filter \(index)")
        }
        .controlSize(.small)
        .frame(height: Theme.FilterRow.height - 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.07 : 0.0))
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset Gain") { profileManager.resetFilter(id: filter.id) }
            Divider()
            Button("Remove Filter", role: .destructive) { profileManager.removeFilter(id: filter.id) }
        }
    }

    /// A committed-on-enter numeric field. Values land only when the user
    /// finishes typing, so a half-entered frequency never reaches the audio.
    private func numericField(
        value: Double,
        unit: String,
        width: CGFloat,
        format: String,
        unitLeading: Bool = false,
        accessibility: String,
        commit: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            if unitLeading {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            TextField(
                "",
                value: Binding(get: { value }, set: { commit($0) }),
                format: .number.precision(.fractionLength(format == "%.2f" ? 2 : (format == "%.1f" ? 1 : 0)))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibility)

            if !unitLeading {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
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

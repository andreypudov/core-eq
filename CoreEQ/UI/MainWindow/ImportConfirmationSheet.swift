import SwiftUI

/// The confirmation shown when an import would change the correction.
///
/// The two-button alert stays for imports that change nothing; this takes over
/// the moment there is something to disclose, because a macOS alert can show
/// only one paragraph and two buttons. The sheet lists every adjustment as its
/// own row, says how far the change moves the response, and — when CoreEQ can
/// represent the beyond-band values another way — lets the user choose.
///
/// Shared by the manual import paths (paste, drop, file) and the AutoEQ
/// catalog's save, so the disclosure reads the same wherever a correction
/// enters the library. Nothing is committed until a button is pressed.
struct ImportConfirmationSheet: View {
    let preview: ProfileManager.ImportPreview

    /// Applies the import with the chosen handling. The longer-lived owner of
    /// the sheet commits and closes; this view only reports the choice.
    let onConfirm: (ImportChoice) -> Void

    /// Leaves everything as it was. No preview state is touched.
    let onCancel: () -> Void

    private var disclosure: ImportDisclosure { preview.disclosure }

    /// The values CoreEQ has to alter, whatever the user decides.
    private var losses: [ImportAdjustment] {
        disclosure.adjustments.filter { $0.kind.isLossy }
    }

    /// The values kept exactly, beyond the graphic range.
    private var kept: [ImportAdjustment] {
        disclosure.adjustments.filter { !$0.kind.isLossy }
    }

    /// The disclosure's measured height, so the scroll area hugs a short list
    /// and stops at the cap for a long one. Seeded at the cap so a first layout
    /// pass never sizes the scroll area to nothing.
    @State private var bodyHeight: CGFloat = maximumDisclosureBodyHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                disclosureBody
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DisclosureBodyHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            // Sizes to the disclosure when it is short, and stops at the cap so
            // the middle scrolls when it is long. The content's height does not
            // depend on the viewport's, so this settles in one extra pass.
            .frame(maxHeight: min(bodyHeight, maximumDisclosureBodyHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(DisclosureBodyHeightKey.self) { bodyHeight = $0 }

            Divider()

            actions
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import adjustments")
    }

    /// What scrolls when the sheet is tall: the adjustment lists, any
    /// skipped-lines note, and the impact.
    private var disclosureBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !losses.isEmpty {
                adjustmentList(title: "CoreEQ will change these", adjustments: losses)
            }

            if !kept.isEmpty {
                adjustmentList(
                    title: "Kept beyond the graphic range",
                    adjustments: kept,
                    explainer:
                        "These are kept exactly, as free filters above the ±12 dB sliders. "
                        + "You can clip their gains to ±12 dB instead."
                )
            }

            if !preview.unparsedLines.isEmpty {
                Text(ImportSummary.skippedLinesSentence(preview.unparsedLines.count))
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
            }

            impactSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Import with Adjustments")
                    .font(Theme.Font.heading)

                Text(ImportSummary.presetSummary(preview))
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Adjustments

    private func adjustmentList(
        title: String,
        adjustments: [ImportAdjustment],
        explainer: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Font.labelEmphasized)

            if let explainer {
                Text(explainer)
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(adjustments) { adjustment in
                    adjustmentRow(adjustment)
                    if adjustment.id != adjustments.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func adjustmentRow(_ adjustment: ImportAdjustment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: glyph(for: adjustment))
                .font(Theme.Font.secondary)
                .foregroundStyle(color(for: adjustment))
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(ImportSummary.filterName(adjustment.filter))
                    .font(Theme.Font.body)

                Text("\(ImportSummary.change(adjustment)) · \(adjustment.limit)")
                    .font(Theme.Font.value)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Text(ImportSummary.status(adjustment))
                .font(Theme.Font.secondary)
                .foregroundStyle(color(for: adjustment))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ImportSummary.adjustmentLine(adjustment))
        .accessibilityValue(ImportSummary.status(adjustment))
    }

    private func glyph(for adjustment: ImportAdjustment) -> String {
        switch adjustment.kind {
        case .droppedFilter: return "trash"
        case .keptBeyondBandRange: return "checkmark.circle"
        default: return "exclamationmark.circle"
        }
    }

    private func color(for adjustment: ImportAdjustment) -> Color {
        switch adjustment.kind {
        case .droppedFilter: return .red
        case .keptBeyondBandRange: return .green
        default: return .orange
        }
    }

    // MARK: - Impact

    private var impactSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How far it moves the response")
                .font(Theme.Font.labelEmphasized)

            impactRow(label: "Import", impact: disclosure.impact)

            if preview.offersClipChoice {
                // `clipImpact` measures exact-to-clipped, the extra move that
                // choosing to clip adds on top of the import — not the clipped
                // result's total distance from what was written.
                impactRow(label: "Extra change from clipping", impact: disclosure.clipImpact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func impactRow(label: String, impact: ImportImpact) -> some View {
        let summary = ImportSummary.impactSummary(impact)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            Text(summary)
                .font(Theme.Font.label)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(summary)")
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            if preview.offersClipChoice {
                Button("Import and Clip to ±12 dB") { onConfirm(.clipBeyondBandRange) }
                    .help(
                        "Clip every beyond-band gain to ±12 dB; use a graphic slider when available"
                    )
            }

            Button("Import") { onConfirm(.keepExact) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Keep every value CoreEQ can represent, exactly as written")
        }
    }
}

extension ProfileManager.ImportPreview: Identifiable {
    /// Identity for the confirmation sheet's `item` binding. Only one preview is
    /// on screen at a time, so its name is enough.
    var id: String { name }
}

/// The tallest the scrollable middle may grow before it scrolls. The header and
/// the buttons stay put; only the disclosure moves, so a correction with dozens
/// of rows cannot push the actions off the sheet.
private let maximumDisclosureBodyHeight: CGFloat = 380

/// Carries the disclosure's natural height up to the scroll area's cap.
private struct DisclosureBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

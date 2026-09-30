import AppKit
import SwiftUI

/// A guide sheet explaining how to bring a headphone correction from
/// autoeq.app into CoreEQ.
///
/// Deliberately general about the site: autoeq.app is someone else's page and
/// changes on its own schedule, so the steps name what to look for rather than
/// quoting its labels, and make no claims about its catalogue.
struct AutoEQGuideSheet: View {
    /// Pastes from the clipboard. The sidebar owns it: it closes this sheet and
    /// shows the same import preview as every other way in.
    let onPaste: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Import from AutoEQ")
                    .font(Theme.Font.heading)
                    .foregroundStyle(.primary)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(
                "AutoEQ publishes correction curves for a large catalogue of headphones and earphones. Its web app can write a correction as an EqualizerAPO parametric EQ, which CoreEQ imports."
            )
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                stepRow(
                    number: "1",
                    title: "Open autoeq.app",
                    detail: "Search for your headphone or earphone model in your browser."
                )

                stepRow(
                    number: "2",
                    title: "Choose a Target",
                    detail:
                        "Pick the sound you want the correction to aim for, and adjust it if you like."
                )

                stepRow(
                    number: "3",
                    title: "Choose EqualizerAPO",
                    detail:
                        "Where the app asks which equalizer you use, choose EqualizerAPO's parametric EQ."
                )

                stepRow(
                    number: "4",
                    title: "Copy or Download",
                    detail:
                        "Copy the generated filters to the clipboard, or download them as a .txt file."
                )

                stepRow(
                    number: "5",
                    title: "Import into CoreEQ",
                    detail:
                        "Click “Paste from Clipboard” below, or drop the .txt file onto the preset list."
                )
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://autoeq.app") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open autoeq.app in Browser", systemImage: "safari")
                }
                .controlSize(.regular)

                Spacer()

                Button {
                    onPaste()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(Theme.Font.valueEmphasized)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(Theme.Font.value)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

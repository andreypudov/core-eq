import AppKit
import SwiftUI

/// A guide sheet explaining how to configure, export, and ingest custom
/// parametric EQ profiles from autoeq.app into CoreEQ.
struct AutoEQGuideSheet: View {
    @ObservedObject var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var pasteError: String?
    @State private var pendingImport: ProfileManager.ImportPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("AutoEQ Web Optimizer")
                    .font(Theme.Font.heading)
                    .foregroundStyle(.primary)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(
                "AutoEq provides measured correction curves for over 5,000 headphones and earphones. You can use their web optimizer to tailor target curves and export them directly to CoreEQ."
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
                    title: "Choose Target Curve",
                    detail:
                        "Select Harman Over-Ear / In-Ear, Diffuse Field, or customize your bass/treble tilt."
                )

                stepRow(
                    number: "3",
                    title: "Select Equalizer App",
                    detail:
                        "In the dropdown, select “EqualizerAPO ParametricEQ” (or Custom Parametric EQ)."
                )

                stepRow(
                    number: "4",
                    title: "Copy or Download",
                    detail:
                        "Copy the generated filter text to your clipboard or download the .txt file."
                )

                stepRow(
                    number: "5",
                    title: "Import into CoreEQ",
                    detail:
                        "Click “Paste from Clipboard” below, or drag and drop the .txt file onto CoreEQ."
                )
            }

            if let pasteError {
                Text(pasteError)
                    .font(Theme.Font.label)
                    .foregroundStyle(.red)
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
                    guard let text = NSPasteboard.general.string(forType: .string) else {
                        pasteError = "No valid EqualizerAPO preset found on clipboard."
                        return
                    }
                    do {
                        pendingImport = try profileManager.previewImport(
                            from: text, name: "Pasted Preset")
                    } catch { pasteError = error.localizedDescription }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 480)
        .alert(
            "Import Preset?",
            isPresented: Binding(
                get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })
        ) {
            Button("Import") {
                if let preview = pendingImport { _ = profileManager.commitImport(preview) }
                pendingImport = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            if let preview = pendingImport {
                let preamp = String(
                    format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), preview.preamp)
                Text("\(preview.name)\n\(preview.filterCount) filters\nPreamp: \(preamp) dB")
            }
        }
    }

    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
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

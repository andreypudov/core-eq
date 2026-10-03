import AppKit
import Combine
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
                Text("Import from AutoEq by Hand")
                    .font(Theme.Font.heading)
                    .foregroundStyle(.primary)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(
                "AutoEq publishes correction curves for a large catalogue of headphones and earphones. Its web app can write a correction as an EqualizerAPO parametric EQ, which CoreEQ imports."
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

/// Asks the sidebar to put the by-hand guide up.
///
/// The catalog window cannot present a sheet over the main window, and it closes
/// on its way out, so the request is left here for the sidebar to pick up. A
/// counter rather than a flag: each request is a distinct event, so opening the
/// guide twice raises it twice. It is not persisted — the guide is a detour, not
/// a place the app returns to, the way `SettingsRoute` chooses a tab every time.
@MainActor
final class AutoEQGuideRoute: ObservableObject {
    static let shared = AutoEQGuideRoute()

    @Published private(set) var request = 0

    func requestGuide() { request &+= 1 }

    private init() {}
}

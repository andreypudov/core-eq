import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The apps CoreEQ leaves alone.
///
/// What this can and cannot do is decided in `AppExclusion`; this pane only
/// edits the list. Every change is written to `SettingsStore` and the engine is
/// told at once, so an app stops — or starts — being equalized while the pane
/// is still open, rather than at some later rebuild nobody can predict.
///
/// The apps someone chose, a switch each, in a standard selectable list with
/// Add and Remove under it.
///
/// Two other layouts were tried and dropped. A list of every installed app read
/// as a long column of checkboxes that belonged to no part of macOS. System
/// Settings' grouped box with + and − needs row selection a grouped form does
/// not have, and drawing one meant matching one macOS release's row metrics by
/// hand. This uses only standard controls, so it follows the system across
/// releases rather than chasing it.
///
/// A switch that is off keeps the app listed and equalized, so a DAW can have
/// its EQ back for a moment without being found and added again.
struct ExclusionsSettingsView: View {
    /// Every listed app, in the order it was added.
    @State private var listed: [String] = []
    /// The listed apps switched on: the ones the tap leaves out.
    @State private var excluded: [String] = []
    @State private var selection: String?

    var body: some View {
        if AppExclusion.isAvailable {
            pane
        } else {
            ContentUnavailableView {
                Label("Requires macOS 26", systemImage: "nosign")
            } description: {
                Text(
                    "Leaving apps out needs macOS 26 or later. On this Mac, CoreEQ equalizes every app."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps switched on below play straight to the output, without EQ.")
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(listed.map(ExcludableApp.init(bundleID:))) { app in
                    row(app).tag(app.bundleID)
                }
            }
            .listStyle(.inset)
            // Room for a full-size icon and switch: at the default height the
            // rows read as a dense table, not a short list of apps.
            .environment(\.defaultMinListRowHeight, 36)
            // A box of its own, as System Settings draws its app lists, from
            // the system's own fill rather than a colour picked here, so it
            // follows the appearance and the release.
            .scrollContentBackground(.hidden)
            .background(
                .fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .onDeleteCommand(perform: removeSelection)
            .overlay {
                if listed.isEmpty {
                    Text("No apps are excluded.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Add…", action: chooseApplications)
                Button("Remove", action: removeSelection)
                    .disabled(selection == nil)
                Spacer()
            }

            Text(
                "Browsers can't be excluded: they play through a helper process that "
                    + "macOS shares between apps."
            )
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear(perform: reload)
    }

    private func row(_ app: ExcludableApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
            Text(app.name)
            Spacer(minLength: 12)
            Toggle("Exclude \(app.name)", isOn: isExcluded(app.bundleID))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .help(app.bundleID)
    }

    // MARK: - Editing

    private func isExcluded(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { excluded.contains(bundleID) },
            set: { isOn in
                save(
                    listed: listed,
                    excluded: isOn ? excluded + [bundleID] : excluded.filter { $0 != bundleID })
            })
    }

    /// Added apps are switched on: adding one is asking for it to be left out.
    private func add(_ bundleIDs: [String]) {
        save(listed: listed + bundleIDs, excluded: excluded + bundleIDs)
    }

    private func removeSelection() {
        guard let bundleID = selection else { return }
        selection = nil
        save(
            listed: listed.filter { $0 != bundleID },
            excluded: excluded.filter { $0 != bundleID })
    }

    private func save(listed newListed: [String], excluded newExcluded: [String]) {
        let settings = SettingsStore()
        let wasExcluded = settings.excludedBundleIDs
        settings.exclusionListBundleIDs = AppExclusion.normalized(newListed)
        settings.excludedBundleIDs = AppExclusion.normalized(newExcluded)
        // Only a change to what the tap leaves out is worth the break in the
        // sound a rebuild costs; listing or removing a switched-off app is not.
        if settings.excludedBundleIDs != wasExcluded {
            EngineStatusBridge.shared.excludedAppsChanged()
        }
        reload()
    }

    private func reload() {
        let settings = SettingsStore()
        listed = settings.exclusionListBundleIDs
        excluded = settings.excludedBundleIDs
    }

    /// Any app on disk, running or not — a DAW is usually excluded before the
    /// session rather than during it. Attached to the Settings window, as
    /// System Settings attaches its own. A helper picked from inside another
    /// app is dropped: excluding it would do nothing (see `AppExclusion`).
    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        Task {
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK else { return }
            add(
                panel.urls.filter(AppExclusion.isStandaloneApp(at:))
                    .compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
    }
}

/// One app as the pane shows it. An identifier with no app behind it — one
/// since deleted — is still listed, by identifier, so it can be removed.
private struct ExcludableApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage

    var id: String { bundleID }

    init(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            self.init(bundleID: bundleID, url: url)
        } else {
            self.init(
                bundleID: bundleID, name: bundleID,
                icon: NSWorkspace.shared.icon(for: .application))
        }
    }

    init(bundleID: String, url: URL) {
        let displayName = FileManager.default.displayName(atPath: url.path)
        self.init(
            bundleID: bundleID,
            name: displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName,
            icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private init(bundleID: String, name: String, icon: NSImage) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
    }
}

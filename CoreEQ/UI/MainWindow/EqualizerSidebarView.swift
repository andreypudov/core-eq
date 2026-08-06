import AppKit
import SwiftUI

/// Sidebar column of the main window: the app mark with the global on/off
/// switch, the preset list, and the add / remove / more actions along the
/// bottom.
///
/// Hosted inside an `NSSplitViewItem(sidebarWithViewController:)`, which
/// supplies the sidebar material and the full-height layout that runs it up
/// behind the titlebar. The item's safe area keeps this content clear of the
/// window controls, so the view itself draws no background of its own.
struct EqualizerSidebarView: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var audioEngine: AudioEngine

    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// Preset the pointer is over, for the row's hover wash.
    @State private var hoveredPreset: String?

    /// Preset awaiting delete confirmation.
    @State private var deletionCandidate: String?

    var body: some View {
        // A plain `VStack` rather than a `List` with safe-area insets: the header
        // is transparent so the sidebar material shows through it, which meant
        // an inset list scrolled its rows *underneath* and made them collide.
        // Stacking gives each piece its own region.
        VStack(alignment: .leading, spacing: 0) {
            appHeader

            enabledRow

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        caption("Presets")
                        ForEach(profileManager.builtInProfiles) { presetRow($0) }

                        if !profileManager.userProfiles.isEmpty {
                            caption("My Presets")
                                .padding(.top, 12)
                            ForEach(profileManager.userProfiles) { presetRow($0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                // Open on the active preset. Without this the list arrives at
                // whatever offset the first layout pass left it at, which for a
                // list taller than the window is the bottom.
                .onAppear { scroll.scrollTo(profileManager.activeProfileName, anchor: .center) }
            }
        }
        .alert("Delete the preset “\(deletionCandidate ?? "")”?", isPresented: deletionAlertPresented) {
            Button("Delete", role: .destructive) {
                if let name = deletionCandidate { profileManager.deleteProfile(named: name) }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("This preset will be removed permanently.")
        }
        // A preset created outside the sidebar arrives as a rename request; seed
        // the field with the generated name so typing replaces it.
        .onChange(of: profileManager.profileAwaitingRename) { _, name in
            if let name { renameText = name }
        }
    }

    /// App mark and name, as an identity block rather than a control.
    private var appHeader: some View {
        HStack(spacing: 10) {
            AppMark()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("CoreEQ")
                    .font(.system(size: 14, weight: .semibold))
                // States what CoreEQ does that Music.app's equalizer doesn't:
                // it shapes every application's output, not one player's. Better
                // here than an adjective — "professional" is a claim about the
                // app, and the window is already making that case on its own.
                Text("System-wide equalizer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    /// The global bypass, on its own row where it reads as the one switch that
    /// governs everything below it.
    private var enabledRow: some View {
        HStack(spacing: 8) {
            Text("Enabled")
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Toggle("Enabled", isOn: $audioEngine.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Equalizer")
                .help("Turn the equalizer on or off")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    /// One preset row.
    ///
    /// Hand-built rather than a `List` row because the selected state here is a
    /// low-opacity green wash, and a `List`'s own selection is a saturated
    /// accent fill that can't be toned down. Everything a source list row owes
    /// the user — click to select, context menu, inline rename — is kept.
    private func presetRow(_ profile: EQProfile) -> some View {
        let isSelected = profile.name == profileManager.activeProfileName
        let isRenaming = profileManager.profileAwaitingRename == profile.name

        return HStack(spacing: 6) {
            if isRenaming {
                TextField("Preset Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { profileManager.profileAwaitingRename = nil }
                    .onAppear { renameFieldFocused = true }
                    // Clicking anywhere outside the field commits, the way
                    // Finder's inline rename does.
                    .onChange(of: renameFieldFocused) { _, isFocused in
                        if !isFocused { commitRename() }
                    }
            } else {
                Text(profile.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if isSelected {
                    if profileManager.isModified {
                        Text("Edited")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill(isSelected: isSelected, isHovered: hoveredPreset == profile.name))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            if profileManager.profileAwaitingRename != nil { commitRename() }
            profileManager.setActiveProfile(name: profile.name)
        }
        .onHover { isInside in
            if isInside {
                hoveredPreset = profile.name
            } else if hoveredPreset == profile.name {
                hoveredPreset = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredPreset)
        .id(profile.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .contextMenu { presetActions(for: profile.name) }
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return .coreEQAccent.opacity(0.18) }
        if isHovered { return .primary.opacity(0.06) }
        return .clear
    }

    /// Every preset action, on the row's context menu.
    ///
    /// With no action bar under the list this menu is the only route to
    /// creating and deleting presets, so "New Preset" leads it rather than
    /// living on a `+` button.
    @ViewBuilder
    private func presetActions(for name: String) -> some View {
        let isEditable = profileManager.canEditProfile(named: name)
        let isActive = name == profileManager.activeProfileName

        Button("New Preset") {
            profileManager.addProfile(filters: profileManager.currentFilters)
        }

        Divider()

        Button("Rename…") { profileManager.beginRename(of: name) }
            .disabled(!isEditable)

        Button("Duplicate") { profileManager.duplicateProfile(named: name) }

        Divider()

        Button("Save Changes") { profileManager.saveChangesToActiveProfile() }
            .disabled(!isEditable || !isActive || !profileManager.isModified)

        Button("Reset to Preset") { profileManager.resetToActiveProfile() }
            .disabled(!isActive || !profileManager.isModified)

        Divider()

        Button("Delete", role: .destructive) { deletionCandidate = name }
            .disabled(!isEditable)
    }

    // MARK: - Preset actions

    private func commitRename() {
        guard let name = profileManager.profileAwaitingRename else { return }
        profileManager.profileAwaitingRename = nil
        profileManager.renameProfile(named: name, to: renameText)
    }

    // MARK: - Bindings

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }
}

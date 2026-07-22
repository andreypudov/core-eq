import SwiftUI

/// The main EQ window: profile selector, one vertical gain slider per band,
/// global bypass toggle, and an engine status footer.
struct MainWindowView: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 20) {
            header
            bandSliders
            footer
        }
        .padding(24)
        .frame(minWidth: 680)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("Profile", selection: profileBinding) {
                ForEach(profileManager.listProfiles()) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .fixedSize()

            if profileManager.isModified {
                Button("Reset") {
                    profileManager.resetToActiveProfile()
                }
                .help("Restore the active profile’s original band values")
            }

            Spacer()

            Toggle("Enabled", isOn: $audioEngine.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(profileManager.currentBands.indices, id: \.self) { index in
                bandControl(at: index)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
    }

    private func bandControl(at index: Int) -> some View {
        let band = profileManager.currentBands[index]
        return VStack(spacing: 6) {
            Text(String(format: "%+.1f", band.gain))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Slider(value: gainBinding(at: index), in: BuiltInProfiles.gainRange, step: 0.5)
                .frame(width: 150)
                .rotationEffect(.degrees(-90))
                .frame(width: 44, height: 150)
                .disabled(!audioEngine.isEnabled)

            Text(frequencyLabel(band.frequency))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(audioEngine.status.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    private var statusColor: Color {
        switch audioEngine.status {
        case .running: return audioEngine.isEnabled ? .green : .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { profileManager.activeProfileName },
            set: { profileManager.setActiveProfile(name: $0) }
        )
    }

    private func gainBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard profileManager.currentBands.indices.contains(index) else { return 0 }
                return profileManager.currentBands[index].gain
            },
            set: { profileManager.setGain($0, forBandAt: index) }
        )
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz == kilohertz.rounded()
                ? "\(Int(kilohertz))k"
                : String(format: "%.1fk", kilohertz)
        }
        return "\(Int(frequency))"
    }
}

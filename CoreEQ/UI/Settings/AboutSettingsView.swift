import SwiftUI

/// What CoreEQ is, where it came from, and what it costs.
///
/// The same four facts the system panel showed, in the app's own hand: the mark,
/// the version, one sentence, and the two places worth going. The copyright and
/// licence keep the smallest type, as they do in every About on the system —
/// they are a statement of fact rather than something to read.
struct AboutSettingsView: View {
    private static let repository = URL(string: "https://github.com/andreypudov/core-eq")!
    /// The release list rather than this version's tag: a tag exists only once
    /// the release is cut, so a build made between releases would link to a 404.
    private static let releases = URL(string: "https://github.com/andreypudov/core-eq/releases")!

    var body: some View {
        VStack(spacing: 10) {
            AppMark()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("CoreEQ")
                    .font(.system(size: 17, weight: .semibold))
                Text(versionLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Equalizes everything you hear, with no driver and nothing left behind.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: 14) {
                Link("Source code", destination: Self.repository)
                Link("Release notes", destination: Self.releases)
            }
            .font(.system(size: 12))

            Text(copyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    /// Read from the bundle rather than written here, so a release cannot ship
    /// an About that disagrees with itself.
    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Version \(version ?? "—")"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}

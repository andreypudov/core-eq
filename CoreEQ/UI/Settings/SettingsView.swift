import SwiftUI

/// The Settings window: what CoreEQ can be told, and what CoreEQ is.
///
/// About is a tab here rather than the system's About panel. The panel is free
/// and correct — it reads the name, version and copyright straight from the
/// bundle — and giving it up means owning those forever. It buys one surface
/// instead of two: a menu bar app has no App menu, so every one of these has to
/// be reached from somewhere else, and one window with two tabs is a shorter
/// answer than a window and a panel.
struct SettingsView: View {
    @ObservedObject private var route = SettingsRoute.shared

    /// One size for both tabs.
    ///
    /// A `TabView` sizes itself to whichever pane is showing, so switching
    /// between a form and a short About block makes the window jump — and in a
    /// window this small, the jump is the most noticeable thing about it. Apple's
    /// own Settings windows do resize between panes, but they are resizing
    /// between panes of comparable weight; these two are not, so both are given
    /// the taller one's height and About centres inside it.
    ///
    /// Set here rather than on each pane so there is one number to change when
    /// General grows another row. Diagnostics is the tallest of the three: it is
    /// the one pane whose content is meant to be read at length.
    ///
    /// The width is set by General's permission row, which is a long label and a
    /// status side by side — at 460 the status wrapped onto its own line, which
    /// reads as though it belonged to nothing. Diagnostics wants the width too:
    /// its report is monospaced, and every line it has to wrap is a line someone
    /// has to reassemble by eye.
    private static let size = CGSize(width: 560, height: 420)

    var body: some View {
        TabView(selection: $route.tab) {
            GeneralSettingsView()
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            DiagnosticsSettingsView()
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)

            AboutSettingsView()
                .frame(width: Self.size.width, height: Self.size.height)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
    }
}

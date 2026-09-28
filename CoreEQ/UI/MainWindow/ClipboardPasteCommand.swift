import AppKit
import SwiftUI

/// Runs an action on ⌘V, but only while the keyboard focus is *not* in a text
/// editor.
///
/// The sidebar wants ⌘V to offer importing a preset from the clipboard. The
/// ready-made way to hang a command off a view is a hidden `Button` with a
/// `.keyboardShortcut`, but a key equivalent belongs to the *window*, not to the
/// view that declares it — so the sidebar's hidden button swallowed ⌘V for the
/// whole window, and pasting into the parametric EQ's value fields did nothing.
///
/// A local event monitor can ask where the focus is before deciding. A field
/// editor is an `NSTextView`, so when one holds the first responder the event is
/// returned untouched and the system pastes into it; otherwise the event is
/// claimed for the action. The monitor answers only while the window hosting
/// this view is key, so it stays quiet behind the Settings window or a sheet.
///
/// Attached as a hidden, non-interactive view so the monitor's lifetime follows
/// the view that owns it rather than the whole application.
struct ClipboardPasteCommand: NSViewRepresentable {
    /// False while a dialog is up, so ⌘V cannot stack a second one behind it.
    var isEnabled: Bool
    /// Runs when ⌘V is claimed. Called on the main actor.
    var action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorHostView(frame: .zero)
        context.coordinator.attach(to: view, isEnabled: isEnabled, action: action)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var isEnabled = true
        var action: @MainActor () -> Void = {}
        private weak var host: NSView?
        private var monitor: Any?

        func attach(to host: NSView, isEnabled: Bool, action: @escaping @MainActor () -> Void) {
            self.host = host
            self.isEnabled = isEnabled
            self.action = action
            guard monitor == nil else { return }
            // Local monitors are delivered on the main thread, which is what
            // lets the handler read AppKit's focus and the pasteboard. The
            // decision comes back as a `Bool` because `assumeIsolated` only
            // carries `Sendable` results, and an `NSEvent` is not one.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let claimed = MainActor.assumeIsolated { self?.claim(event) ?? false }
                return claimed ? nil : event
            }
        }

        func detach() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func claim(_ event: NSEvent) -> Bool {
            guard isEnabled, event.isPasteCommand else { return false }
            guard let window = host?.window, NSApp.keyWindow === window else { return false }
            // A field editor holds the focus while text is being edited; that
            // ⌘V belongs to the text, not to the preset list.
            guard !(window.firstResponder is NSTextView) else { return false }
            // With nothing to import, leave the event to the system rather than
            // telling someone who just meant to paste that the clipboard holds
            // no preset.
            guard let text = NSPasteboard.general.string(forType: .string),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            action()
            return true
        }
    }
}

/// An invisible view that never takes a mouse event. It exists only to give the
/// ⌘V monitor a place in the view hierarchy, so clicks and drags reach whatever
/// is drawn behind it.
private final class MonitorHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSEvent {
    /// Exactly ⌘V. A shifted or optioned paste means something else, and Caps
    /// Lock is ignored because it does not change which command was pressed.
    fileprivate var isPasteCommand: Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags == .command else { return false }
        return charactersIgnoringModifiers?.lowercased() == "v"
    }
}

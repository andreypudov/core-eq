import AppKit

/// The menu header's on/off switch, drawn by CoreEQ rather than by `NSSwitch`.
///
/// `NSSwitch` fills its track with the accent colour only while its app is the
/// active one, and a menu bar app is not active while its menu is open. So in
/// CoreEQ's menu the real switch was grey on and grey off, told apart only by
/// where the knob sat — reported as "users cannot tell at a glance if CoreEQ is
/// running" (#26). Measured rather than assumed: a window claiming to be key
/// did not colour it, and neither did SwiftUI's switch told its window was
/// active, because it draws through `NSSwitch`. The Wi‑Fi menu does not have
/// the problem because Control Center draws its own switches.
///
/// Activating CoreEQ whenever the menu opens would colour the real one, and
/// take the keyboard away from whatever app the user is in — a worse defect
/// than a grey switch. So this copies `NSSwitch` instead: its size is read from
/// the real control at runtime, and the knob's proportions, inset and colours
/// were measured from it on macOS 27, where the knob is a capsule. Earlier
/// systems get a round knob, as `NSSwitch` has there.
///
/// Not a subclass of `NSSwitch`, because none of the ways to recolour one
/// work — each tried: it has no `contentTintColor` or `bezelColor`, public or
/// private; it draws through its own layers (`wantsUpdateLayer`), so an
/// overridden `draw(_:)` is never called; and a Core Image filter on its layer
/// barely tints the edge. Taking over `updateLayer()` would mean drawing all of
/// it here anyway, on top of private layers that may still draw.
@MainActor
final class MenuSwitch: NSControl {
    var isOn: Bool {
        didSet { if isOn != oldValue { updateLayers(animated: true) } }
    }

    private let track = CALayer()
    private let knob = CALayer()
    private let size = NSSwitch().fittingSize

    /// The knob's margin inside the track, on every side.
    private static let inset: CGFloat = 2

    /// Off: a translucent fill that lets the menu's material through, as the
    /// system switch does — measured over an opaque window as 12% white on dark
    /// and 9% black on light.
    private static let offTrack = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09)
    }

    /// Measured: light grey on dark, white on light.
    private static let knobColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.902, alpha: 1) : .white
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { size }

    override var isEnabled: Bool {
        didSet { updateLayers(animated: false) }
    }

    override var wantsUpdateLayer: Bool { true }

    /// Also where an appearance or accent change arrives.
    override func updateLayer() {
        updateLayers(animated: false)
    }

    override func layout() {
        super.layout()
        updateLayers(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        sendAction(action, to: target)
        return true
    }

    private func updateLayers(animated: Bool) {
        let bounds = self.bounds
        let inset = Self.inset
        let knobHeight = bounds.height - inset * 2
        let knobWidth: CGFloat
        if #available(macOS 26, *) {
            // 32 of 54 points, as measured.
            knobWidth = (bounds.width * 32 / 54).rounded()
        } else {
            knobWidth = knobHeight
        }

        var trackColor: CGColor = NSColor.clear.cgColor
        var knobColor: CGColor = NSColor.white.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackColor = (isOn ? NSColor.controlAccentColor : Self.offTrack).cgColor
            knobColor = Self.knobColor.cgColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = trackColor
        knob.frame = CGRect(
            x: isOn ? bounds.width - inset - knobWidth : inset, y: inset,
            width: knobWidth, height: knobHeight)
        knob.cornerRadius = knobHeight / 2
        knob.backgroundColor = knobColor
        // Disabled, the system switch fades its track and keeps its knob.
        track.opacity = isEnabled ? 1 : 0.5
        CATransaction.commit()
    }
}

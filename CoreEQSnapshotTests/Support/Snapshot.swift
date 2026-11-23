import AppKit
import SwiftUI
import Testing

/// Light or dark, the two appearances every snapshot is taken in.
enum SnapshotAppearance: String, CaseIterable, Sendable {
    case light
    case dark

    var appearance: NSAppearance {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)!
    }
}

/// Renders `view` offscreen and compares it with the reference image beside
/// this test file, under `__Snapshots__/<test file>/`.
///
/// References are named `<name>.<appearance>.<language>.png`. The language is
/// the one the host app resolved, plus `-double` under the double-length
/// pseudolanguage, so one test records a separate image for each language it
/// is run in.
///
/// With no reference yet, or with `SNAPSHOT_RECORD=1` in the environment, the
/// rendered image is written as the reference and the test fails so the new
/// image is looked at before it is committed. On a mismatch the actual image
/// and a diff are written to `build/SnapshotFailures/`.
///
/// `afterAppearing` runs once the view is on screen, for what a person would do
/// next — choose something, say. `settle` is the time given afterwards, for a
/// view that loads something in answer.
@MainActor
func expectSnapshot(
    _ view: some View,
    size: CGSize,
    named name: String,
    appearance: SnapshotAppearance,
    settle: TimeInterval = 0,
    afterAppearing: () async -> Void = {},
    filePath: String = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    guard Snapshot.takes(appearance) else { return }
    let image = await Snapshot.render(
        view, width: size.width, height: size.height, appearance: appearance, settle: settle,
        afterAppearing: afterAppearing)
    checkSnapshot(
        image, named: name, appearance: appearance, filePath: filePath,
        sourceLocation: sourceLocation)
}

/// The same, for a view with a fixed width that takes its own height, as a
/// sheet does.
@MainActor
func expectSnapshot(
    _ view: some View,
    width: CGFloat,
    named name: String,
    appearance: SnapshotAppearance,
    settle: TimeInterval = 0,
    afterAppearing: () async -> Void = {},
    filePath: String = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    guard Snapshot.takes(appearance) else { return }
    let image = await Snapshot.render(
        view, width: width, height: nil, appearance: appearance, settle: settle,
        afterAppearing: afterAppearing)
    checkSnapshot(
        image, named: name, appearance: appearance, filePath: filePath,
        sourceLocation: sourceLocation)
}

@MainActor
private func checkSnapshot(
    _ image: CGImage,
    named name: String,
    appearance: SnapshotAppearance,
    filePath: String,
    sourceLocation: SourceLocation
) {
    let testFile = URL(fileURLWithPath: filePath)
    let fileName = "\(name).\(appearance.rawValue).\(Snapshot.language).png"
    let reference = testFile.deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
        .appendingPathComponent(testFile.deletingPathExtension().lastPathComponent)
        .appendingPathComponent(fileName)

    let recording = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    let existing = Snapshot.load(reference)
    // Recording leaves an image that still matches alone: a PNG encoded again
    // differs byte for byte, and ten unchanged files in the diff hide the six
    // that did change.
    if recording, let existing, Snapshot.compare(image, existing).matches { return }
    guard !recording, let expected = existing else {
        Snapshot.write(image, to: reference)
        Issue.record(
            "Recorded \(reference.path). Look at it, then run again to compare.",
            sourceLocation: sourceLocation)
        return
    }

    let comparison = Snapshot.compare(image, expected)
    guard !comparison.matches else { return }

    let failures = Snapshot.repositoryRoot(from: testFile)
        .appendingPathComponent("build/SnapshotFailures")
        .appendingPathComponent(testFile.deletingPathExtension().lastPathComponent)
    let stem = (fileName as NSString).deletingPathExtension
    Snapshot.write(image, to: failures.appendingPathComponent("\(stem).actual.png"))
    if let diff = comparison.diff {
        Snapshot.write(diff, to: failures.appendingPathComponent("\(stem).diff.png"))
    }
    Issue.record(
        "\(fileName) differs from its reference: \(comparison.summary). See \(failures.path).",
        sourceLocation: sourceLocation)
}

/// The pieces behind `expectSnapshot`, kept apart so each can be read alone.
@MainActor
enum Snapshot {
    /// Pixels are rendered at 2x whatever screen the tests run on, so a
    /// reference recorded on a Retina Mac compares on a 1x CI machine.
    static let scale: CGFloat = 2

    /// A channel may move this far (of 255) before the pixel counts as changed:
    /// enough to absorb anti-aliasing noise, far too little to hide a real edit.
    static let channelTolerance = 4

    /// How many changed pixels a snapshot may have and still match.
    ///
    /// A count, not a share of the image. Renders on one machine are identical
    /// to the pixel, so this only has to absorb a stray anti-aliased edge — and
    /// a share does not scale with what matters: 0.1% of a window is about
    /// 2,700 pixels, which let a one-letter change to a button label through.
    static let maxChangedPixels = 20

    /// Whether this configuration snapshots `appearance`. A translation's
    /// configuration sets `SNAPSHOT_APPEARANCES=light`: dark mode changes no
    /// text's length or direction, and every language in both would double
    /// the images for nothing. English and Double-Length take both.
    static func takes(_ appearance: SnapshotAppearance) -> Bool {
        guard let listed = ProcessInfo.processInfo.environment["SNAPSHOT_APPEARANCES"] else {
            return true
        }
        return listed.split(separator: ",").contains { $0 == appearance.rawValue }
    }

    static var language: String {
        let base = Bundle.main.preferredLocalizations.first ?? "en"
        return UserDefaults.standard.bool(forKey: "NSDoubleLocalizedStrings")
            ? "\(base)-double" : base
    }

    /// Hosts the view in a borderless window that is never shown, lets SwiftUI
    /// settle, and draws it into a bitmap.
    /// A nil `height` lets the view take its own.
    static func render(
        _ view: some View, width: CGFloat, height: CGFloat?, appearance: SnapshotAppearance,
        settle: TimeInterval, afterAppearing: () async -> Void
    ) async -> CGImage {
        // On the window background, as in the app. A component alone would
        // otherwise be drawn on nothing, and a transparent PNG shows dark-mode
        // text as white on white in any image viewer.
        let host = NSHostingView(
            rootView: view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
        if height == nil {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
            host.frame.size.height = ceil(host.fittingSize.height)
        } else {
            host.frame = CGRect(x: 0, y: 0, width: width, height: height!)
        }
        var frame = host.frame

        let window = KeyWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentView = host
        defer { window.close() }

        // Waits by suspending, not by spinning the run loop: a spin inside
        // this main-actor function blocks every other main-actor task, so a
        // view that loads something as it appears would never get to. Two
        // short waits first, because the first layout can schedule state
        // changes (geometry readers, onAppear) that land on the next turn.
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        await afterAppearing()
        if settle > 0 {
            try? await Task.sleep(for: .seconds(settle))
        }
        // A view that takes its own height is measured again once it has
        // appeared: what it loads can change it.
        if height == nil {
            frame.size.height = ceil(host.fittingSize.height)
            window.setContentSize(frame.size)
            host.frame = frame
        }
        // No keyboard focus: a focused field draws a text cursor that blinks,
        // and would be in the picture or not depending on the moment.
        window.makeFirstResponder(nil)
        host.layoutSubtreeIfNeeded()
        let size = frame.size

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        appearance.appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: frame, to: rep)
        }
        return normalized(rep.cgImage!)
    }

    /// A window that draws as the key window without ever being shown or
    /// taking focus. Controls draw in their inactive colours otherwise: grey
    /// where the accent would be.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    // MARK: - Comparison

    struct Comparison {
        var matches: Bool
        var summary: String
        var diff: CGImage?
    }

    static func compare(_ actual: CGImage, _ expected: CGImage) -> Comparison {
        guard actual.width == expected.width, actual.height == expected.height else {
            return Comparison(
                matches: false,
                summary:
                    "size \(actual.width)x\(actual.height), expected \(expected.width)x\(expected.height)",
                diff: nil)
        }
        let a = pixels(actual)
        let e = pixels(expected)
        var diff = [UInt8](repeating: 0, count: a.count)
        var changed = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(a[i + channel]) - Int(e[i + channel])))
            }
            if delta > channelTolerance {
                changed += 1
                diff[i] = 255
                diff[i + 3] = 255
            } else {
                // The reference, faded, so the red marks have context.
                let gray = UInt8((Int(e[i]) + Int(e[i + 1]) + Int(e[i + 2])) / 3)
                diff[i] = gray / 4 + 160
                diff[i + 1] = gray / 4 + 160
                diff[i + 2] = gray / 4 + 160
                diff[i + 3] = 255
            }
        }
        let share = Double(changed) / Double(actual.width * actual.height)
        return Comparison(
            matches: changed <= maxChangedPixels,
            summary: String(format: "%d pixels changed (%.3f%%)", changed, share * 100),
            diff: image(diff, width: actual.width, height: actual.height))
    }

    // MARK: - Pixels and files

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// Redraws into 8-bit sRGB RGBA, so images from any source compare byte
    /// for byte.
    static func normalized(_ image: CGImage) -> CGImage {
        self.image(pixels(image), width: image.width, height: image.height)!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo)?.makeImage()
        }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
            let rep = NSBitmapImageRep(data: data), let image = rep.cgImage
        else { return nil }
        return normalized(image)
    }

    static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: url)
    }

    /// The directory holding the Makefile, found by walking up from a test file.
    static func repositoryRoot(from file: URL) -> URL {
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Makefile").path)
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }
}

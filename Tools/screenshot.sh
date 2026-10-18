#!/bin/sh
#
# Takes the README screenshot: opens CoreEQ, sets the main window to a fixed
# size, and captures that window, shadow included, to
# design/screenshots/core-eq-<version>.png.
#
#   Tools/screenshot.sh [path/to/CoreEQ.app]
#
# The release build by default — `make screenshot` builds it first, signed
# with the CoreEQ Release certificate when the keychain has it, so the audio
# permission granted once covers every later build. An ad-hoc build is a new
# app to macOS each time and opens on the Allow card; the script waits for it
# to be answered rather than capturing it.
#
# Plays its own signal during the wait — pink noise with a chord over it — so
# the spectrum behind the curve is the same from one version to the next, and
# shows the active preset's shape: the analyzer draws what CoreEQ outputs. It
# is audible for a few seconds. A running CoreEQ is quit first, because a
# second copy asks which one to keep.
#
# Needs Accessibility (to size the window) and Screen Recording (to capture
# it) for the terminal it runs in. Checked first; a missing one opens its page
# in System Settings.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Release/CoreEQ.app}"
# The size the window opens at on a screen with room, read from the app's own
# source so the two can't drift: MainWindowGeometry.preferred.
preferred=$(sed -n 's/.*static let preferred = CGSize(width: \([0-9_]*\), height: \([0-9_]*\)).*/\1 \2/p' \
    "$ROOT/CoreEQ/UI/MainWindow/MainWindowGeometry.swift" | tr -d _)
WIDTH=${WIDTH:-${preferred% *}}
HEIGHT=${HEIGHT:-${preferred#* }}
SETTLE=${SETTLE:-4}
CARD_TIMEOUT=${CARD_TIMEOUT:-120}
OUT_DIR="$ROOT/design/screenshots"

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
plist="$APP/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
out="$OUT_DIR/core-eq-$version.png"

# Both permissions belong to the terminal running this, and macOS does not ask
# for them on its own: without them the window can't be found or sized, and the
# capture fails. Checked first, before anything is quit or opened.
if [ "$(osascript -e 'tell application "System Events" to get UI elements enabled')" != true ]; then
    echo "error: the terminal needs Accessibility, to size CoreEQ's window." >&2
    echo "Turn it on in the System Settings page now open, then run this again." >&2
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    exit 1
fi
if ! xcrun swift - <<'EOF' 2>/dev/null
import CoreGraphics
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
EOF
then
    echo "error: the terminal needs Screen Recording, to capture CoreEQ's window." >&2
    echo "Turn it on in the System Settings page now open, then run this again." >&2
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    exit 1
fi

work=$(mktemp -d)
player=
cleanup() {
    [ -n "$player" ] && kill "$player" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Generating the test signal"
signal="$work/signal.wav"
xcrun swift - "$signal" $((SETTLE + 30)) 2>/dev/null <<'EOF'
import AVFoundation

// Writes the screenshot's test signal: pink noise with a chord over it, the
// top rolled off — the slope and the peaks of music, the same on every run.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments[2])!
let rate = 48_000.0
let frames = AVAudioFrameCount(seconds * rate)
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames

// A fixed seed, so the noise is the same samples every time.
var state: UInt64 = 0x9E37_79B9_7F4A_7C15
func white() -> Double {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Double(state >> 11) / Double(1 << 53) * 2 - 1
}

// Two notes a fifth apart, A2 and E3, each with its harmonics falling away.
let partials: [(frequency: Double, amplitude: Double)] = [110.0, 164.81].flatMap { root in
    (1...14).map { n in (root * Double(n), 0.09 / Double(n)) }
}

var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
var lowpass = 0.0, rumble = 0.0, rumble2 = 0.0
let lowpassCoefficient = 1 - exp(-2 * Double.pi * 12_000 / rate)
let highpassCoefficient = 1 - exp(-2 * Double.pi * 40 / rate)
var samples = [Double](repeating: 0, count: Int(frames))
for i in 0..<Int(frames) {
    // Paul Kellet's pink filter: white noise falling 3 dB an octave.
    let w = white()
    b0 = 0.99886 * b0 + w * 0.0555179
    b1 = 0.99332 * b1 + w * 0.0750759
    b2 = 0.96900 * b2 + w * 0.1538520
    b3 = 0.86650 * b3 + w * 0.3104856
    b4 = 0.55000 * b4 + w * 0.5329522
    b5 = -0.7616 * b5 - w * 0.0168980
    let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
    b6 = w * 0.115926
    let t = Double(i) / rate
    var tones = 0.0
    for p in partials { tones += p.amplitude * sin(2 * Double.pi * p.frequency * t) }
    lowpass += lowpassCoefficient * (pink + tones - lowpass)
    // Two poles of high-pass at 40 Hz: music has little below it.
    rumble += highpassCoefficient * (lowpass - rumble)
    rumble2 += highpassCoefficient * (lowpass - rumble - rumble2)
    samples[i] = lowpass - rumble - rumble2
}

// Half a second in and out, so it starts and stops without a click, and the
// peak at -6 dBFS.
let peak = samples.map(abs).max()!
let fade = Int(rate / 2)
for i in 0..<Int(frames) {
    let edge = min(i, Int(frames) - 1 - i)
    let gain = 0.5 / peak * min(1, Double(edge) / Double(fade))
    let value = Float(samples[i] * gain)
    buffer.floatChannelData![0][i] = value
    buffer.floatChannelData![1][i] = value
}
// In a function so the file is released, and its header finished, before exit.
func write() throws {
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ],
        commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}
try write()
EOF

if pgrep -x CoreEQ >/dev/null; then
    echo "Quitting the running CoreEQ"
    osascript -e "quit app id \"$bundle_id\""
    while pgrep -x CoreEQ >/dev/null; do sleep 0.2; done
fi

# Where the window goes: near the top left of the sharpest screen. A window is
# captured at the resolution of the screen it is on, so one left on a 1x
# external display comes out at half the detail and in that display's colour
# profile. Printed in System Events' coordinates, top left of the main screen.
position=$(xcrun swift - <<'EOF'
import AppKit
let main = NSScreen.screens[0].frame
let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }!
let visible = screen.visibleFrame
if screen.backingScaleFactor < 2 {
    FileHandle.standardError.write("warning: no Retina screen, capturing at 1x\n".data(using: .utf8)!)
}
print(Int(visible.minX) + 40, Int(main.maxY - visible.maxY) + 40)
EOF
)
x=${position% *}
y=${position#* }

echo "Opening $APP"
open "$APP"

# CoreEQ starts in the menu bar with no window once it has the permission, so
# a launch alone is not enough. Opening it again while it runs brings up the
# main window, the same as opening it from Finder a second time.
windows() {
    osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $1)" 2>/dev/null || echo 0
}
pid=
tries=0
while :; do
    pid=$(pgrep -nx CoreEQ || true)
    if [ -n "$pid" ] && [ "$(windows "$pid")" -gt 0 ]; then break; fi
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
        echo "error: CoreEQ's window did not appear" >&2
        exit 1
    fi
    [ -n "$pid" ] && open "$APP"
    sleep 0.5
done

# The permission card, while CoreEQ has not been allowed to hear the system:
# it fills the window where the graph should be. Found by its Allow… button.
asking() {
    osascript 2>/dev/null <<EOF || echo no
tell application "System Events"
    repeat with e in (entire contents of window 1 of (first process whose unix id is $pid))
        try
            if role of e is "AXButton" and ((name of e as text) & (description of e as text)) contains "Allow" then return "yes"
        end try
    end repeat
    return "no"
end tell
EOF
}
if [ "$(asking)" = yes ]; then
    echo "CoreEQ is asking for the audio permission: click Allow… in its window."
    echo "(A build signed with CoreEQ Release asks once; an ad-hoc build asks every time.)"
    waited=0
    while [ "$(asking)" = yes ]; do
        waited=$((waited + 2))
        if [ "$waited" -ge "$CARD_TIMEOUT" ]; then
            echo "error: the permission was not given" >&2
            exit 1
        fi
        sleep 2
    done
fi

# Moves and sizes the window. Done again after the wait, because the app
# centres its window on the active screen as it opens it, and a first move
# made too early is undone.
place() {
    osascript >/dev/null <<EOF
tell application "System Events"
    set w to window 1 of (first process whose unix id is $pid)
    set position of w to {$x, $y}
    set size of w to {$WIDTH, $HEIGHT}
end tell
EOF
}
sleep 1
place
echo "Playing the test signal for $SETTLE s"
afplay "$signal" &
player=$!
sleep "$SETTLE"
place
sleep 0.5

# The window server's id for the main window: the largest normal-level window
# the process owns, which skips the menu bar extra.
window_id=$(xcrun swift - "$pid" <<'EOF'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let main = windows
    .filter { $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0 }
    .max { area($0) < area($1) }
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
print(main?[kCGWindowNumber as String] as? Int ?? 0)
EOF
)
[ "$window_id" != 0 ] || { echo "error: CoreEQ's window was not found" >&2; exit 1; }

mkdir -p "$OUT_DIR"
echo "Capturing the window"
screencapture -x -l "$window_id" "$out" || {
    echo "error: the capture failed" >&2
    exit 1
}
kill "$player" 2>/dev/null
player=
width=$(sips -g pixelWidth "$out" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$out" | awk '/pixelHeight/ {print $2}')
echo "Saved $out (${width} x ${height} px)"
# Twice the window's width, and its shadow, at 2x. Less means it was captured
# on a 1x screen.
[ "$width" -ge $((WIDTH * 2)) ] || echo "warning: captured at 1x, not Retina" >&2

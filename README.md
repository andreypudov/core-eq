# CoreEQ

A system-wide equalizer for macOS: a menu bar app that applies a multi-band EQ
to **everything you hear**, with instant profile switching and a simple,
standard EQ window.

## Requirements

- **macOS 14.2 or later.** CoreEQ intercepts system audio with the Core Audio
  process-tap API (`AudioHardwareCreateProcessTap`), which Apple introduced in
  macOS 14.2. This is the only way to process all system audio without
  installing a virtual audio driver, so the deployment target is 14.2 rather
  than 13.0.
- **System Audio Recording permission.** On first launch macOS asks for
  permission to record system audio (System Settings → Privacy & Security →
  Screen & System Audio Recording). Without it the tap cannot be created and
  CoreEQ reports an engine error in the menu and main window.
- Xcode 16 or later to build.

## How CoreEQ attaches to system audio

Everything lives in `CoreEQ/AudioEngine.swift` and `CoreEQ/EQProcessor.swift`:

1. **Process tap.** The engine creates a global Core Audio process tap covering
   every process except CoreEQ itself (excluding itself prevents a feedback
   loop). The tap uses `muteBehavior = .mutedWhenTapped`, so the original audio
   of the tapped processes is silenced at the hardware — the only signal that
   reaches the speakers is what CoreEQ writes back.
2. **Private aggregate device.** The tap and the current default output device
   are combined into a private (invisible to the user) aggregate device with
   drift compensation, so tap input and device output share one IO cycle.
3. **IO proc.** An IO proc on the aggregate receives the tapped system mix as
   input each cycle, runs it through the EQ, and writes it to the output
   buffers of the real device.
4. **DSP.** The EQ is a cascade of RBJ peaking biquads (transposed direct form
   II, per band and channel). Parameter changes are handed to the realtime
   thread through a try-lock so the render path never blocks, and gain changes
   are smoothed over ~50 ms — switching profiles or dragging sliders is
   glitch-free. Custom biquads were chosen over wrapping an Audio Unit because
   they are trivially realtime-safe inside a HAL IO proc and have no format
   negotiation edge cases.

The engine rebuilds the whole chain automatically when the default output
device changes or the Mac wakes from sleep, and tracks sample rate changes with
a device property listener. Bypass ("Enable Equalizer") keeps the tap running
and passes audio through untouched, so toggling is instant.

## Profiles

Profiles are defined in `CoreEQ/EQProfile.swift`. All profiles share seven
fixed bands — 60, 150, 400, 1k, 2.5k, 6k, 12k Hz (Q 1.1, gain ±12 dB) — so a
profile is just a named list of gains:

Flat, Bass Boost, Treble Boost, V-Shaped, Voice / Podcast, Classical / Neutral.

Selecting a profile (menu bar or main window) applies its gains immediately.
Dragging a band slider tweaks the current profile; tweaks persist across
restarts until another profile is selected. The active profile name, custom
gains, and the enabled/bypass state are stored in `UserDefaults`
(`CoreEQ/SettingsStore.swift`) and restored on launch.

## Project layout

```
CoreEQ.xcodeproj        Xcode project (folder-synchronized sources)
Config/Info.plist       LSUIElement, NSAudioCaptureUsageDescription
CoreEQ/
  CoreEQApp.swift       SwiftUI entry point + AppDelegate (wiring, main window)
  AudioEngine.swift     Tap + aggregate device + IO proc, device-change handling
  EQProcessor.swift     Realtime biquad EQ with parameter smoothing
  EQProfile.swift       EQBand / EQProfile models, built-in profiles
  ProfileManager.swift  Active profile + working band values, persistence
  SettingsStore.swift   UserDefaults wrapper
  MenuBarController.swift  NSStatusItem menu (profiles, bypass, open, quit)
  MainWindowView.swift  SwiftUI EQ window (profile picker, sliders, status)
```

## Building and running

Open `CoreEQ.xcodeproj` in Xcode and run, or from the command line:

```sh
xcodebuild -project CoreEQ.xcodeproj -target CoreEQ -configuration Debug build
```

CoreEQ runs as a menu bar app (no Dock icon). Click the sliders icon in the
menu bar to switch profiles, toggle the EQ, or open the main window.

The app is currently unsandboxed and ad-hoc signed for local development;
App Store distribution would need sandboxing plus the appropriate audio
entitlements revisited.

## Known limitations

- Stereo processing only: additional channels on multi-channel devices pass
  through unequalized.
- Profiles are fixed; there is no UI for creating or saving custom named
  profiles yet (tweaks to the active profile do persist).
- No output level meter yet.

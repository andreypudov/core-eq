# CoreEQ – System-wide macOS Equalizer  
CLAUDE.md

## 1. Project overview

**Name:** CoreEQ  
**Platform:** macOS (Sonoma and later; target minimum 13.0 unless otherwise specified)  
**Language:** Swift (SwiftUI for UI, AppKit/AudioToolbox/CoreAudio where needed)  
**Goal:** Provide a **stable, system-wide equalizer** with a **simple, standard EQ UI** and **menu bar access to profiles**.

CoreEQ should feel like a professional audio utility: minimal, reliable, and focused on its core function—equalization of system audio.

---

## 2. Core requirements

### 2.1 Functional requirements

- **System-wide EQ:**
  - **Intercept and process all system audio output** (not per-app).
  - Apply EQ filters to the main output device (e.g., default system output).
  - Maintain audio stability: no crackling, dropouts, or noticeable latency.

- **Equalizer engine:**
  - Implement a **multi-band EQ** (start with 5–10 bands; parametric or fixed-frequency graphic EQ).
  - Each band should support:
    - **Gain** (in dB).
    - **Frequency** (Hz) — configurable or fixed depending on design.
    - **Q / bandwidth** (for parametric bands).
  - Use **CoreAudio / AudioUnit** APIs for DSP:
    - Prefer **Apple’s built-in EQ Audio Unit** if available for stability.
    - Alternatively, implement custom biquad filters with robust, tested DSP.

- **Presets / profiles:**
  - Provide a **predefined list of EQ profiles**, e.g.:
    - **Flat** (no change).
    - **Bass Boost**.
    - **Treble Boost**.
    - **V-shaped** (bass + treble emphasis).
    - **Podcast / Voice** (mid emphasis, clarity).
    - **Classical / Neutral** (gentle, wide-band shaping).
  - Each profile is a named set of band parameters.
  - Profiles must be **stored persistently** (e.g., in `UserDefaults` or a small config file).
  - User can **switch profiles instantly** without audio glitches.

- **Menu bar integration:**
  - CoreEQ runs as a **menu bar app**.
  - **Menu bar icon** always visible while CoreEQ is running.
  - From the menu bar:
    - **Select EQ profile** directly (no need to open main UI).
    - Show current active profile.
    - Provide basic controls:
      - **Enable/disable EQ** (bypass).
      - **Open main UI**.
      - **Quit CoreEQ**.

- **Main UI (simple EQ interface):**
  - Use **SwiftUI** for the main window UI.
  - Provide:
    - **Profile selector** (dropdown or list).
    - **Band controls**:
      - Sliders for gain (and optionally frequency/Q).
      - Visual grouping by frequency range (low, mid, high).
    - **Global bypass** toggle.
    - **Output level meter** (optional, but helpful).
  - UI should be **clean, minimal, and standard** for EQ tools—no unnecessary visual complexity.

---

## 3. Non-functional requirements

### 3.1 Stability and performance

- **Primary focus:** stability and reliability.
- Audio processing must:
  - Avoid buffer underruns and overruns.
  - Maintain **low latency** suitable for everyday use.
- Handle:
  - **Device changes** (e.g., user switches output device).
  - **Sleep/wake** events.
  - **Sample rate changes** gracefully.

### 3.2 Professional macOS guidelines

- Follow **Apple Human Interface Guidelines**:
  - Consistent menu bar behavior.
  - Standard keyboard shortcuts where appropriate.
  - Respect system appearance (Light/Dark mode).
- Use **sandboxing and entitlements** correctly:
  - If system-wide audio requires special entitlements, document and structure code accordingly.
- Provide **proper app lifecycle management**:
  - Clean startup/shutdown of audio units.
  - Avoid leaving dangling audio resources.

### 3.3 Configuration and persistence

- Persist:
  - **Current active profile**.
  - **Custom profile modifications** (if allowed).
  - **EQ enabled/disabled state**.
- On app restart:
  - Restore last used profile and state.
  - Reattach to default output device and reapply EQ.

---

## 4. High-level architecture

### 4.1 Modules

1. **AudioEngine**
   - Responsibilities:
     - Attach to system output (or virtual device if required).
     - Manage Audio Units / CoreAudio graph.
     - Apply EQ parameters (bands, gains, frequencies).
     - Handle device changes and errors.
   - Key components:
     - `AudioEngine` class (Swift).
     - `EQProcessor` (DSP logic or wrapper around Apple EQ Audio Unit).
     - `ProfileManager` (loads and applies profiles).

2. **ProfileManager**
   - Responsibilities:
     - Store predefined profiles.
     - Load/save current profile to persistent storage.
     - Provide API:
       - `listProfiles() -> [EQProfile]`
       - `setActiveProfile(name: String)`
       - `getActiveProfile() -> EQProfile`
   - Data model:
     - `EQProfile` struct:
       - `name: String`
       - `bands: [EQBand]`
     - `EQBand` struct:
       - `frequency: Double`
       - `gain: Double`
       - `q: Double` (optional for graphic EQ).

3. **MenuBarController**
   - Responsibilities:
     - Create and manage **NSStatusItem** (menu bar icon).
     - Build menu:
       - List of profiles (radio items).
       - Bypass toggle.
       - “Open CoreEQ…” item.
       - “Quit CoreEQ” item.
     - Communicate with `AudioEngine` and `ProfileManager`.

4. **MainUI (SwiftUI)**
   - Responsibilities:
     - Provide main window for detailed EQ control.
     - Bind to `AudioEngine` and `ProfileManager` via observable objects.
   - Views:
     - `CoreEQApp` (entry point).
     - `MainWindowView`:
       - Profile selector.
       - Band sliders.
       - Bypass toggle.
       - Optional meters.

5. **Persistence**
   - Use `UserDefaults` or a small JSON file for:
     - Active profile name.
     - EQ enabled state.
   - Provide a simple `SettingsStore` abstraction.

---

## 5. Initial feature set (MVP)

### 5.1 MVP scope

Focus on **stability and core EQ functionality**:

- **AudioEngine:**
  - Attach to default output device.
  - Use a stable EQ Audio Unit (prefer built-in if available).
  - Implement 5–7 fixed bands (e.g., 60 Hz, 250 Hz, 1 kHz, 4 kHz, 10 kHz).
  - Support gain adjustment per band.

- **Profiles:**
  - Hard-code a small set of profiles in code initially:
    - Flat
    - Bass Boost
    - Treble Boost
    - V-shaped
    - Voice/Podcast
  - Switching profiles updates band gains and applies immediately.

- **Menu bar:**
  - NSStatusItem with:
    - Current profile (checked).
    - List of profiles.
    - Bypass toggle.
    - Open UI.
    - Quit.

- **Main UI:**
  - Single window with:
    - Profile dropdown.
    - Sliders for each band’s gain.
    - Bypass toggle.

- **Persistence:**
  - Store active profile and bypass state in `UserDefaults`.

---

## 6. Implementation guidelines

### 6.1 Swift and frameworks

- **Language:** Swift (latest stable version supported by Xcode).
- **UI:** SwiftUI for main window; AppKit for menu bar integration.
- **Audio:** CoreAudio / AudioUnit / AVAudioEngine (choose the most stable path for system-wide EQ).

### 6.2 Code style and structure

- Use **clear, modular structure**:
  - `AudioEngine.swift`
  - `EQProfile.swift`
  - `ProfileManager.swift`
  - `MenuBarController.swift`
  - `CoreEQApp.swift` (SwiftUI entry point)
- Follow **Swift API Design Guidelines**:
  - Descriptive names.
  - Avoid global state; use dependency injection where reasonable.

### 6.3 Error handling

- AudioEngine must:
  - Log and handle errors gracefully.
  - Attempt reconnection on device changes.
  - Provide user feedback only when necessary (e.g., via subtle notifications or status changes).

---

## 7. User interaction flows

### 7.1 Menu bar profile selection

1. User clicks CoreEQ icon in the menu bar.
2. Menu opens showing:
   - Active profile (checked).
   - Other profiles as selectable items.
   - Bypass toggle.
   - “Open CoreEQ…” and “Quit”.
3. User selects a profile.
4. `MenuBarController` calls `ProfileManager.setActiveProfile(name)`.
5. `AudioEngine` receives updated profile and applies band gains.
6. Audio changes immediately, without opening the main UI.

### 7.2 Main UI usage

1. User selects “Open CoreEQ…” from menu bar.
2. Main window appears.
3. User:
   - Changes profile via dropdown.
   - Adjusts band sliders.
   - Toggles bypass.
4. Changes are reflected in real-time in `AudioEngine`.
5. On close, state is persisted.

---

## 8. Future extensions (not required for initial implementation)

These are **out of scope for now**, but the architecture should not block them:

- Per-output-device profiles.
- Per-app EQ routing.
- Advanced visualizations (spectrum analyzer).
- Import/export of profiles.
- Headphone-specific presets (e.g., CoreEQ profiles for specific models).

---

## 9. Deliverables for first implementation

For the initial version of CoreEQ, Claude should produce:

1. **Project skeleton:**
   - Xcode-compatible Swift project.
   - App entry point with SwiftUI.
   - NSStatusItem-based menu bar integration.

2. **AudioEngine implementation:**
   - Basic system-wide audio attachment.
   - EQ processing using a stable Audio Unit.
   - API to apply `EQProfile`.

3. **ProfileManager and models:**
   - `EQProfile` and `EQBand` structs.
   - Hard-coded predefined profiles.
   - Persistence of active profile and bypass state.

4. **MenuBarController:**
   - Menu bar icon and menu.
   - Profile selection.
   - Bypass toggle.
   - Open UI / Quit actions.

5. **Main UI (SwiftUI):**
   - Simple window with profile selector and band sliders.
   - Bypass toggle.

6. **Basic documentation:**
   - Short README section inside the project explaining:
     - How CoreEQ attaches to system audio.
     - How profiles are defined and applied.

---

## 10. Priorities

1. **Stability of audio engine** (no glitches, safe handling of device changes).
2. **Correct system-wide EQ behavior**.
3. **Reliable profile switching from menu bar**.
4. **Simple, clear UI for EQ control**.
5. **Clean code structure following professional macOS development practices**.

CoreEQ should feel like a focused, professional tool: minimal, predictable, and trustworthy for everyday listening and analytical use.



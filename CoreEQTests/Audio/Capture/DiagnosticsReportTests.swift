import Testing

/// The report a user pastes into an issue.
///
/// Worth testing because it is read by someone who cannot see the machine it
/// describes: a field that silently goes missing, or a fallback that is not
/// called out, turns a report that would have settled a bug into one that
/// misleads.
struct DiagnosticsReportTests {

    private func device(
        name: String = "Test Device",
        aggregate: Bool = false,
        buffers: [Int] = [2],
        streams: [Int] = [2],
        stereo: StereoPair? = StereoPair(left: 0, right: 1)
    ) -> DiagnosticsReport.Device {
        DiagnosticsReport.Device(
            name: name, uid: "uid", transport: "USB", isAggregate: aggregate,
            isDefaultOutput: true, bufferChannels: buffers, streamChannels: streams,
            preferredStereo: stereo)
    }

    private func engine(
        deviceBound: Bool = true,
        tapChannels: Int = 8,
        destinations: [Int] = [0, 1, 2, 3, 4, 5, 6, 7]
    ) -> DiagnosticsReport.Engine {
        DiagnosticsReport.Engine(
            status: "running", deviceName: "Test Device", sampleRate: 48_000,
            tapChannels: tapChannels, isDeviceBound: deviceBound, boundStream: 0,
            destinations: destinations, aggregateChannels: 8)
    }

    private func text(
        permission: TapAccess = .granted,
        devices: [DiagnosticsReport.Device] = [],
        engine: DiagnosticsReport.Engine? = nil,
        profiles: DiagnosticsReport.Profiles? = nil
    ) -> String {
        DiagnosticsReport.text(
            appVersion: "1.8 (1)", systemVersion: "Version 15.0", permission: permission,
            devices: devices, engine: engine, profiles: profiles)
    }

    private func profiles(
        stored: String? = "Flat", storedSlot: String? = "A",
        live: String? = "Flat", liveSlot: String? = "A"
    ) -> DiagnosticsReport.Profiles {
        DiagnosticsReport.Profiles(
            currentDeviceUID: "BuiltInSpeakerDevice", savedSlots: ["BuiltInSpeakerDevice"],
            storedProfileName: stored, storedSlot: storedSlot,
            liveProfileName: live, liveSlot: liveSlot)
    }

    // MARK: - Profiles

    /// The point of reporting both halves: a preset that comes back wrong is
    /// usually filed correctly and wrong on screen, which one half cannot show.
    @Test func aProfileMismatchIsCalledOut() {
        let report = text(profiles: profiles(stored: "Flat", live: "Rock"))
        #expect(report.contains("MISMATCH"))
    }

    /// The A/B slot is half the state, so disagreeing on it is a mismatch too —
    /// the same preset in the other slot is a different sound.
    @Test func aSlotMismatchIsCalledOut() {
        let report = text(profiles: profiles(storedSlot: "A", liveSlot: "B"))
        #expect(report.contains("MISMATCH"))
    }

    @Test func agreementIsNotReportedAsAMismatch() {
        #expect(!text(profiles: profiles()).contains("MISMATCH"))
    }

    @Test func bothHalvesAreShown() {
        let report = text(profiles: profiles(stored: "Flat", live: "Rock", liveSlot: "B"))

        #expect(report.contains("on screen:       Rock, slot B"))
        #expect(report.contains("filed:           Flat, slot A"))
    }

    /// A device with nothing filed yet is not a mismatch to be chased.
    @Test func anUnfiledDeviceReadsAsNothing() {
        let report = text(
            profiles: profiles(stored: nil, storedSlot: nil, live: nil, liveSlot: nil))

        #expect(report.contains("filed:           nothing"))
        #expect(!report.contains("MISMATCH"))
    }

    @Test func theHeaderCarriesBothVersions() {
        let report = text()
        #expect(report.contains("CoreEQ 1.8 (1)"))
        #expect(report.contains("macOS Version 15.0"))
    }

    /// The two facts have to be read together. "Not capturing" while muting is
    /// a silent Mac; "not capturing" while unmuted is CoreEQ standing aside,
    /// which is the state it is designed to fail into.
    @Test func aTapThatIsNotYetMutingSaysSo() {
        var engine = self.engine()
        engine.isMuting = false

        #expect(text(engine: engine).contains("muting others:   no"))
        #expect(text(engine: engine).contains("audio is left alone"))
    }

    @Test func aProvenTapReportsThatItIsMuting() {
        var engine = self.engine()
        engine.isMuting = true

        #expect(text(engine: engine).contains("muting others:   yes"))
    }

    /// Whether the tap is delivering anything is the fact that separates
    /// "nothing is playing" from "nothing is reaching us". A report read by
    /// someone chasing a silent Mac has to state it either way.
    @Test func aCapturingTapIsReported() {
        var engine = self.engine()
        engine.hasReceivedAudio = true

        #expect(text(engine: engine).contains("capturing:       yes"))
    }

    @Test func aTapThatHasDeliveredNothingIsReported() {
        var engine = self.engine()
        engine.hasReceivedAudio = false

        #expect(text(engine: engine).contains("no audio seen since the engine started"))
    }

    /// A stopped engine has to say so. A report that simply omits the section
    /// reads as though the engine were fine.
    // MARK: - The permission

    /// The first question any audio problem raises, so it is reported whether or
    /// not the engine is running.
    @Test func aGrantedPermissionIsReported() {
        #expect(text(permission: .granted).contains("System audio permission: granted"))
    }

    @Test func aRefusedPermissionIsReported() {
        #expect(text(permission: .denied).contains("System audio permission: REFUSED"))
    }

    /// The engine can fail before it ever attempts a tap — refusing an
    /// unsupported output device does exactly that — and the report must not
    /// then imply the permission was refused.
    @Test func anUndeterminedPermissionIsNotReportedAsRefused() {
        let report = text(permission: .unknown)

        #expect(report.contains("not determined this session"))
        #expect(!report.contains("REFUSED"))
    }

    /// A failing engine says nothing about the permission, and the report has to
    /// keep those two facts apart.
    @Test func aFailedEngineDoesNotImplyARefusedPermission() {
        let report = text(permission: .granted, engine: nil)

        #expect(report.contains("System audio permission: granted"))
        #expect(report.contains("not running"))
    }

    @Test func aStoppedEngineIsStated() {
        #expect(text().contains("not running"))
    }

    /// The single most useful line in the whole report: whether the audio was
    /// mixed to stereo before CoreEQ ever saw it.
    @Test func theMixdownFallbackIsCalledOut() {
        let report = text(engine: engine(deviceBound: false, tapChannels: 2, destinations: [0, 1]))

        #expect(report.contains("stereo mixdown (fallback)"))
        #expect(report.contains("mixed to stereo before CoreEQ sees it"))
    }

    /// The device-bound tap is the good case and must not carry the warning.
    @Test func aDeviceBoundTapCarriesNoMixdownWarning() {
        let report = text(engine: engine())

        #expect(report.contains("device-bound on stream 0"))
        #expect(!report.contains("mixed to stereo before CoreEQ sees it"))
    }

    @Test func theChannelMapIsShown() {
        let report = text(engine: engine(tapChannels: 2, destinations: [4, 5]))
        #expect(report.contains("tap 0 → 4, tap 1 → 5"))
    }

    /// A dropped channel is the shape of a real bug, so it is named rather than
    /// printed as a bare -1.
    @Test func aDroppedChannelIsNamed() {
        let report = text(engine: engine(tapChannels: 2, destinations: [0, -1]))
        #expect(report.contains("tap 1 → dropped"))
    }

    @Test func aMultiBufferDeviceShowsItsShape() {
        let report = text(devices: [device(buffers: [2, 2], streams: [2, 2])])

        #expect(report.contains("2 [2 + 2], 4 channels"))
        #expect(report.contains("2 [2ch, 2ch]"))
    }

    /// An aggregate output is the configuration CoreEQ refuses, so the report
    /// has to say why rather than leaving the reader to wonder.
    @Test func anAggregateDeviceIsFlagged() {
        let report = text(devices: [device(aggregate: true)])
        #expect(report.contains("CoreEQ cannot render through one"))
    }

    @Test func aDeviceThatReportsNoStereoPairSaysSo() {
        let report = text(devices: [device(stereo: nil)])
        #expect(report.contains("stereo pair:   not reported"))
    }

    @Test func theDefaultOutputIsMarked() {
        #expect(text(devices: [device()]).contains("<- system default"))
    }

    @Test func noDevicesIsStatedRatherThanBlank() {
        #expect(text().contains("none found"))
    }
    // MARK: - The sample-rate window

    /// The quiet case has to say something. "No line" and "a line saying none"
    /// read identically to someone who does not know the line exists, and this
    /// report is read by people who have never seen another one.
    @Test func aReportWithNoRateWindowSaysSo() {
        #expect(text(engine: engine()).contains("rate window:     none seen"))
    }

    /// The number that matters is not the duration; it is where the bands went.
    /// "41 ms" tells a reader nothing they can act on.
    @Test func aRateWindowNamesWhereTheBandsWent() {
        var stale = engine()
        stale.rateWindow = RateWindow.Measurement(
            seconds: 0.041, cycles: 4, configuredRate: 44_100, observedRate: 16_000)

        let report = text(engine: stale)

        #expect(report.contains("41 ms"))
        #expect(report.contains("44100 Hz"))
        #expect(report.contains("16000 Hz"))
        #expect(report.contains("1 kHz band sat at 363 Hz"))
    }

    // MARK: - Output level

    /// The line that settles the open noise reports. Both halves have to be
    /// unambiguous: a reader who has never seen this report cannot tell a
    /// missing line from a healthy one.
    @Test func aChainWithHeadroomToSpareSaysSo() {
        var quiet = engine()
        quiet.level = DiagnosticsReport.Level(peak: 0.71, clippedSamples: 0)

        let report = text(engine: quiet)

        #expect(report.contains("peak output:     0.71, no clipping"))
        #expect(report.contains("NOTE: the chain produces more than fits") == false)
    }

    /// Clipping is the first hypothesis for "it sounds broken at higher volume",
    /// and the one thing the user cannot check for themselves — the level
    /// arriving at a tap depends on what is playing.
    @Test func aClippingChainIsNamedAndExplained() {
        var loud = engine()
        loud.level = DiagnosticsReport.Level(peak: 1.84, clippedSamples: 4_812)

        let report = text(engine: loud)

        #expect(report.contains("1.84"))
        #expect(report.contains("4812 sample(s) clipped"))
        #expect(report.contains("as distortion rather than loudness"))
    }

    /// One sample over is still clipping. A threshold that ignored a handful
    /// would hide the intermittent case, which is the one people report.
    @Test func aSingleClippedSampleCounts() {
        #expect(DiagnosticsReport.Level(peak: 1.0001, clippedSamples: 1).isClipping)
        #expect(DiagnosticsReport.Level(peak: 1.0, clippedSamples: 0).isClipping == false)
    }

    // MARK: - Restarts and uptime

    /// "No audio seen" means nothing without knowing for how long.
    @Test func theReportSaysHowLongTheEngineHasBeenUp() {
        var running = engine()
        running.uptime = 754

        #expect(text(engine: running).contains("up 13 min"))
    }

    @Test func aFreshEngineReportsRestartsAsNone() {
        #expect(text(engine: engine()).contains("restarts:        none"))
    }

    /// The wake-from-sleep echo is a report of something that happens after a
    /// restart, so the reason and the age are the whole point of the line.
    @Test func aRestartIsNamedWithItsReasonAndAge() {
        var restarted = engine()
        restarted.restarts = DiagnosticsReport.Restarts(
            count: 3, lastReason: "system woke from sleep", since: 240)

        let report = text(engine: restarted)

        #expect(report.contains("restarts:        3"))
        #expect(report.contains("system woke from sleep"))
        #expect(report.contains("4 min ago"))
    }

    /// Durations are rounded to the unit a reader thinks in, and every case here
    /// is a boundary where the wrong choice reads absurdly. The 3_599 one is the
    /// reason minutes are tested after rounding rather than before: it used to
    /// report "60 min", which is not how anyone says an hour.
    @Test func durationsAreReportedInReadableUnits() {
        let cases = [
            (45.0, "up 45 sec"),
            (89.0, "up 89 sec"),
            (90.0, "up 2 min"),
            (600.0, "up 10 min"),
            (3_540.0, "up 59 min"),
            (3_599.0, "up 1.0 hr"),
            (3_600.0, "up 1.0 hr"),
            (5_400.0, "up 1.5 hr"),
            (86_400.0, "up 24.0 hr"),
            (259_200.0, "up 3.0 days"),
        ]
        for (seconds, expected) in cases {
            var running = engine()
            running.uptime = seconds
            #expect(text(engine: running).contains(expected), "\(seconds)s read wrongly")
        }
    }

}

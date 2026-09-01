import Foundation
import Testing

/// Sizing the interval where the filters ran at the wrong sample rate.
///
/// The traces here are written by hand precisely because the real ones are not
/// reproducible on demand — they come off a Bluetooth headset changing profile
/// mid-call. If the arithmetic that reads them is wrong, the measurement is
/// worth nothing and there is no way to notice from the output.
struct RateWindowTests {

    /// A tidy timebase, so a cycle's host-time delta reads as microseconds.
    private static let ticks = 1_000_000.0

    /// Cycles delivering `frames` at `actualRate`, while the filters believe
    /// `configuredRate`.
    private func cycles(
        count: Int,
        frames: Int = 512,
        actualRate: Double,
        configuredRate: Double,
        from hostTime: UInt64 = 1_000,
        sampleTime: Double = 0
    ) -> [RateCycle] {
        let step = UInt64((Double(frames) / actualRate) * Self.ticks)
        return (0..<count).map { index in
            RateCycle(
                hostTime: hostTime &+ UInt64(index) &* step,
                sampleTime: sampleTime > 0 ? sampleTime + Double(index * frames) : 0,
                frames: frames,
                configuredRate: configuredRate)
        }
    }

    // MARK: - Reading the cadence

    /// The cadence is the rate. Nothing else in the system reports it in time.
    @Test func theObservedRateComesFromTheCadence() {
        let readings = RateWindow.readings(
            cycles(count: 5, actualRate: 48_000, configuredRate: 48_000),
            ticksPerSecond: Self.ticks)

        #expect(readings.count == 4, "a cadence needs two cycles, so one is spent")
        for reading in readings {
            #expect(abs(reading.observedRate - 48_000) < 100)
            #expect(reading.disagrees == false)
        }
    }

    /// The device's own sample clock is used when Core Audio marks it valid,
    /// because a frame count is only what was asked for.
    @Test func theSampleClockIsPreferredWhenItIsValid() {
        let withClock = cycles(
            count: 4, actualRate: 48_000, configuredRate: 48_000, sampleTime: 900_000)
        let readings = RateWindow.readings(withClock, ticksPerSecond: Self.ticks)

        #expect(readings.allSatisfy { abs($0.observedRate - 48_000) < 100 })
    }

    /// A trace of one cycle says nothing about cadence, and must not pretend to.
    @Test func aSingleCycleYieldsNoReading() {
        let readings = RateWindow.readings(
            cycles(count: 1, actualRate: 48_000, configuredRate: 48_000),
            ticksPerSecond: Self.ticks)

        #expect(readings.isEmpty)
    }

    @Test func anEmptyTraceIsNotAnError() {
        #expect(RateWindow.readings([], ticksPerSecond: Self.ticks).isEmpty)
        #expect(RateWindow.widest([]) == nil)
    }

    // MARK: - The window

    /// The case this exists for: a headset moving to its call profile while the
    /// filters are still built for 48 kHz.
    @Test func aCallProfileFlipIsMeasured() {
        let before = cycles(count: 4, actualRate: 48_000, configuredRate: 48_000)
        let stale = cycles(
            count: 3, actualRate: 16_000, configuredRate: 48_000,
            from: before.last!.hostTime &+ 10_667)
        let after = cycles(
            count: 4, actualRate: 16_000, configuredRate: 16_000,
            from: stale.last!.hostTime &+ 32_000)

        let widest = RateWindow.widest(
            RateWindow.readings(before + stale + after, ticksPerSecond: Self.ticks))
        let measurement = try! #require(widest)

        #expect(measurement.configuredRate == 48_000)
        #expect(abs(measurement.observedRate - 16_000) < 500)
        #expect(measurement.seconds > 0)
    }

    /// What the user actually heard, which is the number worth reporting.
    @Test func theWindowSaysWhereTheBandsWent() {
        let measurement = RateWindow.Measurement(
            seconds: 0.037, cycles: 3, configuredRate: 48_000, observedRate: 16_000)

        #expect(abs(measurement.displacedKilohertzBand - 333) < 1)
    }

    /// Agreement is the normal case and must never be reported as a window.
    @Test func aSteadyRateHasNoWindow() {
        let readings = RateWindow.readings(
            cycles(count: 20, actualRate: 44_100, configuredRate: 44_100),
            ticksPerSecond: Self.ticks)

        #expect(RateWindow.widest(readings) == nil)
    }

    /// 44.1 to 48 kHz is a 9% step. It is deliberately below the threshold: it
    /// puts a 1 kHz band at 1088 Hz, which is not something anyone can hear, and
    /// reporting it would bury the case that matters in ones that do not.
    @Test func theCommonRateStepIsNotReportedAsAFault() {
        let stale = cycles(count: 6, actualRate: 48_000, configuredRate: 44_100)
        let readings = RateWindow.readings(stale, ticksPerSecond: Self.ticks)

        #expect(RateWindow.widest(readings) == nil)
    }

    /// Scheduling jitter is not a rate change. An IO thread that wakes late once
    /// must not be recorded as the device having changed underneath us.
    @Test func aLateWakeUpIsNotAWindow() {
        var trace = cycles(count: 8, actualRate: 48_000, configuredRate: 48_000)
        // One cycle arrives 5% late, then the cadence resumes.
        for index in 4..<trace.count {
            trace[index].hostTime &+= 530
        }

        let readings = RateWindow.readings(trace, ticksPerSecond: Self.ticks)
        #expect(RateWindow.widest(readings) == nil)
    }

    /// A trace can hold more than one route change. The worst is what decides
    /// whether this is worth fixing, so that is what is reported.
    @Test func theWidestWindowWins() {
        let steady = cycles(count: 2, actualRate: 48_000, configuredRate: 48_000)
        let brief = cycles(
            count: 2, actualRate: 16_000, configuredRate: 48_000,
            from: steady.last!.hostTime &+ 10_667)
        let recovered = cycles(
            count: 2, actualRate: 48_000, configuredRate: 48_000,
            from: brief.last!.hostTime &+ 32_000)
        let long = cycles(
            count: 9, actualRate: 16_000, configuredRate: 48_000,
            from: recovered.last!.hostTime &+ 10_667)

        let readings = RateWindow.readings(
            steady + brief + recovered + long, ticksPerSecond: Self.ticks)
        let measurement = try! #require(RateWindow.widest(readings))

        #expect(measurement.cycles >= 8, "the brief window was reported instead of the long one")
    }

    /// A trace that ends while the rate still disagrees still measures what it
    /// saw, rather than discarding an unfinished window — the dump is taken on a
    /// timer, so an unfinished window is a real outcome.
    @Test func anUnfinishedWindowIsStillMeasured() {
        let steady = cycles(count: 2, actualRate: 48_000, configuredRate: 48_000)
        let stale = cycles(
            count: 5, actualRate: 16_000, configuredRate: 48_000,
            from: steady.last!.hostTime &+ 10_667)

        let readings = RateWindow.readings(steady + stale, ticksPerSecond: Self.ticks)
        #expect(RateWindow.widest(readings) != nil)
    }

    // MARK: - The report

    @Test func theReportNamesTheWindowAndTheDisplacement() {
        let before = cycles(count: 2, actualRate: 48_000, configuredRate: 48_000)
        let stale = cycles(
            count: 4, actualRate: 16_000, configuredRate: 48_000,
            from: before.last!.hostTime &+ 10_667)
        let events = [
            RateEvent(hostTime: stale[1].hostTime, kind: .listenerFired, rate: 0),
            RateEvent(hostTime: stale[3].hostTime, kind: .coefficientsRecomputed, rate: 16_000),
        ]

        let report = RateWindow.report(
            cycles: before + stale, events: events, ticksPerSecond: Self.ticks)

        #expect(report.contains("WINDOW"))
        #expect(report.contains("1 kHz band sat at"))
        #expect(report.contains("coefficients recomputed"))
        #expect(report.contains("stale"))
    }

    @Test func aQuietReportSaysSoRatherThanNothing() {
        let report = RateWindow.report(
            cycles: cycles(count: 6, actualRate: 48_000, configuredRate: 48_000),
            events: [], ticksPerSecond: Self.ticks)

        #expect(report.contains("no disagreement"))
    }

    /// An event older than the oldest cycle still in the ring is ordinary: the
    /// two rings are different lengths and are written by different threads.
    /// Subtracting host times unsigned turned that into 768614336339369 ms,
    /// which reads as a broken clock rather than as "before the trace begins".
    @Test func anEventBeforeTheTraceReadsAsNegative() {
        let trace = cycles(count: 4, actualRate: 48_000, configuredRate: 48_000, from: 100_000)
        let earlier = [RateEvent(hostTime: 40_000, kind: .listenerFired, rate: 0)]

        let report = RateWindow.report(
            cycles: trace, events: earlier, ticksPerSecond: Self.ticks)

        #expect(report.contains("-60.00 ms"), "an early event did not read as negative")
        #expect(report.contains("768614") == false, "unsigned underflow is back")
    }

    /// The summary is what goes to the log, where a message is truncated long
    /// before a few hundred cycles of table would fit.
    @Test func theSummaryStandsAloneAndNamesTheWindow() {
        let before = cycles(count: 2, actualRate: 44_100, configuredRate: 44_100)
        let stale = cycles(
            count: 5, actualRate: 16_000, configuredRate: 44_100,
            from: before.last!.hostTime &+ 11_610)

        let summary = RateWindow.summary(
            RateWindow.readings(before + stale, ticksPerSecond: Self.ticks))

        #expect(summary.contains("WINDOW"))
        #expect(summary.contains("44100"))
        #expect(summary.contains("16000"))
        #expect(summary.count < 200, "a summary this long risks being truncated in the log")
    }
}

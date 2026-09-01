import Foundation

/// Reading a `RateTrace` after the fact.
///
/// The device's true rate is not something CoreEQ is told in time; it is
/// something the IO cadence reveals. Frames delivered divided by real time
/// elapsed *is* the rate, and comparing that against the rate the filters were
/// built for gives the interval where the two disagreed — the window this
/// exists to size.
///
/// Pure, and separated from the recording for the usual reason: the arithmetic
/// is the part worth being sure about, and it can be checked against traces
/// written by hand rather than by a Bluetooth headset.
enum RateWindow {

    /// How far the observed rate may sit from the configured one before the two
    /// are called different.
    ///
    /// Ten percent is well above IO scheduling jitter and well below the two to
    /// three times a Bluetooth call profile moves things, so it separates the
    /// case worth finding from the noise without needing to be exact. It also
    /// sits above the 44.1 to 48 kHz step (9%), which is deliberate: that change
    /// puts a 1 kHz band at 1088 Hz, which is not a defect anyone can hear.
    static let tolerance = 0.10

    /// What one cycle implies about the device's real rate.
    struct Reading: Equatable {
        var hostTime: UInt64
        /// Seconds since the previous cycle.
        var elapsed: Double
        /// Frames per second, as the cadence implies.
        var observedRate: Double
        /// What the filters were designed for at that moment.
        var configuredRate: Double

        /// Whether the filters were wrong about the rate for this cycle.
        var disagrees: Bool {
            guard configuredRate > 0, observedRate > 0 else { return false }
            return abs(observedRate / configuredRate - 1) > RateWindow.tolerance
        }
    }

    /// An interval where the filters ran at the wrong rate.
    struct Measurement: Equatable {
        /// Width of the window.
        var seconds: Double
        /// IO cycles filtered with the wrong coefficients.
        var cycles: Int
        /// What the filters were built for while it lasted.
        var configuredRate: Double
        /// What the device was actually running at.
        var observedRate: Double

        /// Where a band designed for 1 kHz actually sat during the window.
        ///
        /// The number to quote in a report: "37 ms" says nothing on its own,
        /// "37 ms with every band a third of where it should be" says what the
        /// user heard.
        var displacedKilohertzBand: Double {
            guard configuredRate > 0 else { return 0 }
            return 1_000 * observedRate / configuredRate
        }
    }

    /// Turns raw cycles into per-cycle readings.
    ///
    /// The device's own sample clock is used when Core Audio marked it valid,
    /// since it is exact where a frame count is only nominal; the frame count is
    /// the fallback. The first cycle yields nothing — a cadence needs two.
    static func readings(_ cycles: [RateCycle], ticksPerSecond: Double) -> [Reading] {
        guard ticksPerSecond > 0 else { return [] }
        var readings: [Reading] = []
        readings.reserveCapacity(max(0, cycles.count - 1))

        for index in 1..<max(cycles.count, 1) {
            let previous = cycles[index - 1]
            let current = cycles[index]
            let elapsed = Double(current.hostTime &- previous.hostTime) / ticksPerSecond
            guard elapsed > 0 else { continue }

            let advanced =
                (current.sampleTime > 0 && previous.sampleTime > 0)
                ? current.sampleTime - previous.sampleTime
                : Double(previous.frames)
            guard advanced > 0 else { continue }

            readings.append(
                Reading(
                    hostTime: current.hostTime,
                    elapsed: elapsed,
                    observedRate: advanced / elapsed,
                    configuredRate: current.configuredRate))
        }
        return readings
    }

    /// The widest interval in the trace where the two disagreed.
    ///
    /// Widest rather than first: a trace can hold several route changes, and the
    /// worst one is what decides whether this needs fixing.
    static func widest(_ readings: [Reading]) -> Measurement? {
        var widest: Measurement?
        var start: Reading?
        var count = 0

        func close(at end: Reading) {
            guard let opened = start else { return }
            let seconds = Double(end.hostTime &- opened.hostTime) / RateTrace.ticksPerSecond
            let measurement = Measurement(
                seconds: seconds,
                cycles: count,
                configuredRate: opened.configuredRate,
                observedRate: opened.observedRate)
            if seconds > (widest?.seconds ?? -1) { widest = measurement }
            start = nil
            count = 0
        }

        for reading in readings {
            if reading.disagrees {
                if start == nil { start = reading }
                count += 1
            } else {
                close(at: reading)
            }
        }
        // A trace that ends mid-disagreement still measures what it saw.
        if let last = readings.last, start != nil { close(at: last) }

        return widest
    }

    /// The trace as a table, for the log.
    ///
    /// Every cycle, not a summary: the summary is what is in question, and a
    /// table is what lets a wrong summary be spotted.
    static func report(
        cycles: [RateCycle], events: [RateEvent], ticksPerSecond: Double = RateTrace.ticksPerSecond
    ) -> String {
        let readings = readings(cycles, ticksPerSecond: ticksPerSecond)
        guard let origin = cycles.first?.hostTime else { return "rate trace: empty" }

        // Signed deliberately. Events are marked on the main thread and cycles
        // on the render thread, into rings of different lengths, so an event can
        // easily be older than the oldest cycle still held. Unsigned subtraction
        // turns that into 768614336339369 ms, which reads as a broken clock
        // rather than as "this happened before the trace begins".
        func offset(_ hostTime: UInt64) -> Double {
            (Double(hostTime) - Double(origin)) / ticksPerSecond * 1_000
        }

        var lines: [String] = [summary(readings)]

        for event in events {
            lines.append(
                String(
                    format: "  %8.2f ms  %@", offset(event.hostTime), describe(event)))
        }

        lines.append("       t/ms   elapsed/ms   observed/Hz   configured/Hz")
        for reading in readings {
            lines.append(
                String(
                    format: "  %9.2f %12.3f %13.0f %15.0f%@",
                    offset(reading.hostTime), reading.elapsed * 1_000, reading.observedRate,
                    reading.configuredRate, reading.disagrees ? "  <-- stale" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The one line worth logging: what was found, if anything.
    ///
    /// Separate from `report` because a trace runs to hundreds of cycles and
    /// `os_log` truncates a message long before that — the first attempt at
    /// this logged the whole table and lost exactly the rows being looked for.
    /// The summary goes to the log, the table goes to a file.
    static func summary(_ readings: [Reading]) -> String {
        guard let widest = widest(readings) else {
            return "rate trace: \(readings.count) cycles, "
                + "no disagreement beyond \(Int(tolerance * 100))%"
        }
        return String(
            format:
                "rate trace: %d cycles, WINDOW %.1f ms over %d cycles: "
                + "configured %.0f Hz, actual %.0f Hz (a 1 kHz band sat at %.0f Hz)",
            readings.count, widest.seconds * 1_000, widest.cycles, widest.configuredRate,
            widest.observedRate, widest.displacedKilohertzBand)
    }

    /// Words for a tag, on the main thread where words are free.
    static func describe(_ event: RateEvent) -> String {
        let rate = event.rate > 0 ? " (\(Int(event.rate)) Hz)" : ""
        switch event.kind {
        case .listenerFired: return "Core Audio reported a rate change" + rate
        case .rateStaged: return "new rate staged for the render thread" + rate
        case .coefficientsRecomputed: return "coefficients recomputed" + rate
        }
    }
}

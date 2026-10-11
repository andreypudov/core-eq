import Foundation
import Testing

extension AutoEQIntegrationTests {
    struct LocalSolver {
        @Test func fitsSyntheticTargetWithinOneDecibel() throws {
            let frequencies = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: frequencies, raw: frequencies.map { _ in 0 })
            let target = AutoEQCurve(
                frequency: frequencies,
                raw: frequencies.map { frequency in
                    let bass = 3.0 / (1 + pow(frequency / 160, 2))
                    let presence = 2.0 * exp(-pow(log(frequency / 2_800), 2) / 0.18)
                    return bass + presence
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(label: "Synthetic", compatible: [], recommended: [], fr: target))
            let errors = frequencies.filter { $0 <= 6000 }.map { frequency in
                result.filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: frequency)
                } - target.value(at: frequency)
            }
            let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
            #expect(rms < 1.0, "Synthetic response RMS: \(rms) dB")
            #expect(result.filters.count == AutoEQLocalSolver.filterCount)
            #expect(result.filters.allSatisfy { (-12...12).contains($0.gain) })
            #expect((-12...0).contains(result.preamp))
        }

        @Test func fitsOverlappingBroadCutsAndBoosts() throws {
            let grid = AutoEQLocalSolver.frequencies
            let reference = [
                AutoEQEqualizedFilter(type: "PEAKING", fc: 120, q: 0.3, gain: -8),
                AutoEQEqualizedFilter(type: "PEAKING", fc: 400, q: 0.7, gain: 7),
                AutoEQEqualizedFilter(type: "PEAKING", fc: 2000, q: 2, gain: -4),
                AutoEQEqualizedFilter(type: "HIGH_SHELF", fc: 10_000, q: 0.7, gain: -5),
            ]
            let targetCurve = AutoEQCurve(
                frequency: grid,
                raw: grid.map { f in
                    reference.reduce(0) { $0 + AutoEQLocalSolver.response($1, at: f) }
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: .init(frequency: grid, raw: grid.map { _ in 0 }),
                target: .init(
                    label: "Overlapping", compatible: [], recommended: [], fr: targetCurve))
            let alignmentGrid = (0..<696).map { 20 * pow(1.01, Double($0)) }
                .filter { $0 >= 100 && $0 <= 10_000 }
            let offset =
                alignmentGrid.reduce(0) { $0 + targetCurve.value(at: $1) }
                / Double(alignmentGrid.count)
            let errors = grid.filter { $0 <= 6000 }.map { f in
                result.filters.reduce(0) { $0 + AutoEQLocalSolver.response($1, at: f) }
                    - targetCurve.value(at: f) + offset
            }
            let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
            #expect(rms < 0.3, "Overlapping response RMS: \(rms) dB")
        }

        @Test func measurementAndTargetLevelOffsetsDoNotChangeCorrection() throws {
            let grid = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: grid,
                raw: grid.map {
                    3 * sin(log($0 / 100))
                })
            let target = AutoEQTarget(
                label: "Flat", compatible: [], recommended: [],
                fr: .init(frequency: grid, raw: grid.map { _ in 0 }))
            let original = try AutoEQLocalSolver.compute(measurement: measurement, target: target)
            var shiftedTarget = target
            shiftedTarget.fr?.raw = grid.map { _ in -17 }
            let shifted = try AutoEQLocalSolver.compute(
                measurement: .init(frequency: grid, raw: measurement.raw.map { $0 + 23 }),
                target: shiftedTarget)
            let errors = grid.map { f in
                let a = original.filters.reduce(0) { $0 + AutoEQLocalSolver.response($1, at: f) }
                let b = shifted.filters.reduce(0) { $0 + AutoEQLocalSolver.response($1, at: f) }
                return abs(a - b)
            }
            #expect(errors.max()! < 0.05)
            #expect(abs(original.preamp - shifted.preamp) < 0.11)
        }

        @Test func oneKilohertzNotchDoesNotBiasWholeCorrection() throws {
            let grid = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: grid,
                raw: grid.map {
                    -6 * exp(-pow(log($0 / 1000), 2) / 0.005)
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(
                    label: "Flat", compatible: [], recommended: [],
                    fr: .init(frequency: grid, raw: grid.map { _ in 0 })))
            // A narrow dip at 1 kHz must not create a broad six-decibel cut.
            for f in [100.0, 300, 3000, 10_000] {
                let response = result.filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: f)
                }
                #expect(abs(response) < 0.6)
            }
        }

        /// A narrow measurement dip drives the error positive; `desired` is capped
        /// at +6 dB, so the boost side is bounded by construction. Smoothing
        /// attenuates, but does not eliminate, the narrow feature.
        @Test func narrowMidBandDipStaysBoundedUnderPositiveCap() throws {
            let grid = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: grid,
                raw: grid.map { frequency in
                    -20 * exp(-pow(log(frequency / 1500), 2) / 0.002)
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(
                    label: "Flat", compatible: [], recommended: [],
                    fr: .init(frequency: grid, raw: grid.map { _ in 0 })))
            func response(at frequency: Double) -> Double {
                result.filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: frequency)
                }
            }
            // Away from the dip the correction must stay near flat.
            for frequency in [100.0, 300, 3000, 10_000] {
                #expect(abs(response(at: frequency)) < 0.6)
            }
            // No narrow ringing spike beside the boost; the measured minimum
            // there is about -0.61 dB.
            let minimum = (1000...2500).map { response(at: Double($0)) }.min()!
            #expect(minimum > -1.0, "beside-dip minimum response: \(minimum) dB")
            // The +6 dB cap applies to `desired`, not the fitted output, so
            // overlapping filters may overshoot slightly. Measured about +7.09 dB.
            let atDip = response(at: 1500)
            #expect(atDip > 0 && atDip <= 7.5, "dip response: \(atDip) dB")
        }

        /// A narrow measurement peak drives the error negative. Unlike the boost
        /// side, `desired` has no lower clamp (upstream cuts peaks), so this is
        /// where an unbounded fit would show. The cut must stay bounded and must
        /// not ring into a positive spike beside it.
        @Test func narrowMidBandPeakCutStaysBounded() throws {
            let grid = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: grid,
                raw: grid.map { frequency in
                    20 * exp(-pow(log(frequency / 1500), 2) / 0.002)
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(
                    label: "Flat", compatible: [], recommended: [],
                    fr: .init(frequency: grid, raw: grid.map { _ in 0 })))
            func response(at frequency: Double) -> Double {
                result.filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: frequency)
                }
            }
            // Away from the peak the correction must stay near flat.
            for frequency in [100.0, 300, 3000, 10_000] {
                #expect(abs(response(at: frequency)) < 0.6)
            }
            // No positive ringing spike beside the cut; measured max ~+0.70 dB.
            let maximum = (1000...2500).map { response(at: Double($0)) }.max()!
            #expect(maximum < 1.0, "beside-peak maximum response: \(maximum) dB")
            // The uncapped cut side tracks the +20 dB peak rather than diverging;
            // measured about -17.95 dB at the peak.
            let atPeak = response(at: 1500)
            #expect(atPeak < -15 && atPeak > -20.5, "peak response: \(atPeak) dB")
        }

        @Test func broadTrebleCorrectionSurvivesSmoothing() throws {
            let grid = AutoEQLocalSolver.frequencies
            let shelf = AutoEQEqualizedFilter(type: "HIGH_SHELF", fc: 10_000, q: 0.7, gain: -5)
            let measurement = AutoEQCurve(
                frequency: grid,
                raw: grid.map {
                    -AutoEQLocalSolver.response(shelf, at: $0)
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(
                    label: "Flat", compatible: [], recommended: [],
                    fr: .init(frequency: grid, raw: grid.map { _ in 0 })))
            let treble = result.filters.reduce(0) {
                $0 + AutoEQLocalSolver.response($1, at: 16_000)
            }
            #expect(treble < -3.5)
        }

        @Test func smoothingPreservesQuadraticIncludingEdges() throws {
            let grid = (0..<696).map { 20 * pow(1.01, Double($0)) }
            let values = grid.map { 1 + 0.2 * log($0) + 0.03 * pow(log($0), 2) }
            let smoothed = try AutoEQLocalSolver.smooth(.init(frequency: grid, raw: values))
            for i in grid.indices {
                #expect(abs(smoothed.raw[i] - values[i]) < 1e-9)
            }
        }

        @Test func smoothingUsesUpstreamWindowAndTrebleBlend() throws {
            let grid = (0..<696).map { 20 * pow(1.01, Double($0)) }
            var impulse = grid.map { _ in 0.0 }
            impulse[200] = 21
            let smoothed = try AutoEQLocalSolver.smooth(.init(frequency: grid, raw: impulse))
            // 1/12 octave at a 1.01 step gives a seven-point quadratic SG kernel.
            let expected = [-2.0, 3, 6, 7, 6, 3, -2]
            for i in expected.indices {
                #expect(abs(smoothed.raw[197 + i] - expected[i]) < 1e-6)
            }
            let ripple = grid.indices.map { $0.isMultiple(of: 2) ? 2.0 : -2.0 }
            let filtered = try AutoEQLocalSolver.smooth(.init(frequency: grid, raw: ripple))
            let treble = zip(grid, filtered.raw).filter { $0.0 > 10_000 && $0.0 < 15_000 }
            #expect(treble.allSatisfy { abs($0.1) < 0.05 })
        }

        @Test func headroomUsesCombinedResponseInsteadOfSumOfGains() throws {
            let filters = [80.0, 800, 8000].map {
                AutoEQEqualizedFilter(type: "PEAKING", fc: $0, q: 4, gain: 6)
            }
            let peak = try AutoEQLocalSolver.peakGain(filters)
            #expect(filters.reduce(0) { $0 + $1.gain } == 18)
            #expect(peak > 6 && peak < 6.2)
            // Independent, denser grids at playback rates verify the sampled bound.
            for rate in [44_100.0, 48_000, 96_000, 192_000] {
                for i in 0..<8192 {
                    let f = pow(rate * 0.499, Double(i) / 8191)
                    let combined = filters.reduce(0) {
                        $0 + AutoEQLocalSolver.response($1, at: f, sampleRate: rate)
                    }
                    #expect(combined < peak + 0.01)
                }
            }
        }

        @Test func finalizationDoesNotCapSummedPositiveGains() throws {
            let filters = [80.0, 800, 8000].map {
                AutoEQEqualizedFilter(type: "PEAKING", fc: $0, q: 4, gain: 6)
            }
            let finalized = try AutoEQLocalSolver.finalizedProfile(filters)
            #expect(finalized.filters == filters)
            #expect(finalized.preamp > -6.5)
            #expect(finalized.filters.reduce(0) { $0 + max(0, $1.gain) } == 18)
        }

        @Test func finalizationReducesExcessPeakToFitPreampRange() throws {
            let filters = (0..<10).map { _ in
                AutoEQEqualizedFilter(type: "PEAKING", fc: 1000, q: 1, gain: 6)
            }
            let finalized = try AutoEQLocalSolver.finalizedProfile(filters)
            let peak = try AutoEQLocalSolver.peakGain(finalized.filters)
            #expect(peak <= 11.8)
            #expect(finalized.preamp >= -12)
            #expect(finalized.preamp + peak <= -0.199)
            #expect(finalized.filters.allSatisfy { $0.gain > 0 && $0.gain < 6 })
        }

        @Test func fittedProfileKeepsHeadroomAfterImport() throws {
            let grid = AutoEQLocalSolver.frequencies
            let desired = grid.map { f in
                [70.0, 350, 2200, 4500].reduce(0.0) {
                    $0 + 5 * exp(-pow(log(f / $1), 2) / 0.025)
                }
            }
            let fitted = try AutoEQLocalSolver.compute(
                measurement: .init(frequency: grid, raw: grid.map { _ in 0 }),
                target: .init(
                    label: "Peaks", compatible: [], recommended: [],
                    fr: .init(frequency: grid, raw: desired)))
            let profile = try AutoEQProfileBuilder.makeProfile(model: "Peaks", equalized: fitted)
                .exact
            let peak = try AutoEQLocalSolver.peakGain(fitted.filters)
            #expect(profile.preamp >= -12)
            #expect(profile.preamp + peak <= -0.199)
            #expect(abs(profile.preamp + peak) < 0.301)
        }

        @Test func invalidInputsAndCancellation() async throws {
            #expect(throws: AutoEQError.malformedData) {
                try AutoEQCurve.csv(Data("frequency,raw\n20,nan\n30,0".utf8))
            }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                let curve = AutoEQCurve(frequency: [20, 20_000], raw: [0, 0])
                return try AutoEQLocalSolver.compute(
                    measurement: curve,
                    target: .init(label: "Flat", compatible: [], recommended: [], fr: curve))
            }
            do {
                _ = try await task.value
                Issue.record("Expected cancellation")
            } catch is CancellationError {}
        }
    }
}

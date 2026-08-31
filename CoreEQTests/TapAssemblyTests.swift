import CoreAudio
import Foundation
import Testing

/// Which taps a device needs, and what to do when only some can be made.
///
/// This is the half of the audio path that had no tests at all. Every defect
/// found while building multichannel support was in decisions like these rather
/// than in the DSP — and none was reachable, because they sat in a `@MainActor`
/// type full of Core Audio calls. Behind `TapFactory` they are ordinary code.
@MainActor
struct TapAssemblyTests {

    /// Records what was asked of it and answers as instructed.
    private final class FakeTapFactory: TapFactory {
        /// Channels each device-bound stream will report, by stream index.
        var streamChannels: [Int: Int]
        /// Stream indices whose tap creation fails.
        var failingStreams: Set<Int>
        /// Whether the stereo mixdown can be made at all.
        var globalTapWorks: Bool

        private(set) var requestedStreams: [Int] = []
        private(set) var globalTapRequests = 0
        private(set) var destroyed: [AudioObjectID] = []
        private var nextID: AudioObjectID = 1

        init(
            streamChannels: [Int: Int] = [:],
            failingStreams: Set<Int> = [],
            globalTapWorks: Bool = true
        ) {
            self.streamChannels = streamChannels
            self.failingStreams = failingStreams
            self.globalTapWorks = globalTapWorks
        }

        func makeDeviceBoundTap(stream: Int) throws -> AssembledTap {
            requestedStreams.append(stream)
            guard !failingStreams.contains(stream) else { throw TapUnavailable(status: -1) }
            defer { nextID += 1 }
            return AssembledTap(
                id: nextID, uuid: UUID(), channels: streamChannels[stream] ?? 2,
                stream: stream, isDeviceBound: true)
        }

        func makeGlobalTap() throws -> AssembledTap {
            globalTapRequests += 1
            guard globalTapWorks else { throw TapUnavailable(status: -2) }
            defer { nextID += 1 }
            return AssembledTap(
                id: nextID, uuid: UUID(), channels: 2, stream: -1, isDeviceBound: false)
        }

        func destroy(_ tap: AssembledTap) { destroyed.append(tap.id) }
    }

    // MARK: - One stream

    /// The ordinary case, and the one verified on hardware: a device presenting
    /// all its channels as a single stream needs a single tap.
    @Test func aSingleStreamDeviceGetsOneTap() throws {
        let factory = FakeTapFactory(streamChannels: [0: 16])

        let taps = try TapAssembly.taps(forStreams: [16], using: factory)

        #expect(taps.count == 1)
        #expect(taps[0].channels == 16)
        #expect(taps[0].isDeviceBound)
        #expect(taps[0].firstChannel == 0)
        #expect(factory.globalTapRequests == 0, "the mixdown was taken unnecessarily")
    }

    // MARK: - Several streams

    /// The path that hardware here cannot reach. An interface presenting eight
    /// stereo streams needs eight taps: binding to the widest alone would
    /// capture two channels and abandon fourteen.
    @Test func everyStreamGetsItsOwnTap() throws {
        let channels = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, 2) })
        let factory = FakeTapFactory(streamChannels: channels)

        let taps = try TapAssembly.taps(forStreams: Array(repeating: 2, count: 8), using: factory)

        #expect(taps.count == 8)
        #expect(factory.requestedStreams == Array(0..<8))
        #expect(taps.map(\.firstChannel) == [0, 2, 4, 6, 8, 10, 12, 14])
    }

    /// Streams need not be the same width, and each tap's offset is the running
    /// total of the ones before it.
    @Test func unevenStreamsGetAccumulatedOffsets() throws {
        let factory = FakeTapFactory(streamChannels: [0: 8, 1: 2, 2: 4])

        let taps = try TapAssembly.taps(forStreams: [8, 2, 4], using: factory)

        #expect(taps.map(\.channels) == [8, 2, 4])
        #expect(taps.map(\.firstChannel) == [0, 8, 10])
    }

    // MARK: - When only some taps can be made

    /// Partial success is not a usable device: the streams that did tap would be
    /// muted and replaced while the rest played on untouched, so some of the
    /// audio would be equalized and some would not. The made taps have to be
    /// destroyed, not left running.
    @Test func aPartialSetIsDestroyedRatherThanUsed() throws {
        let channels = Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, 2) })
        let factory = FakeTapFactory(streamChannels: channels, failingStreams: [2])

        let taps = try TapAssembly.taps(forStreams: [2, 2, 2, 2], using: factory)

        #expect(factory.destroyed.count == 2, "the taps already made were left running")
        #expect(taps.count == 1, "a partial set was used as though it were whole")
    }

    /// Having given up on per-stream taps, the next attempt is the widest single
    /// stream — still device-bound, still no mixdown.
    @Test func aPartialSetFallsBackToTheWidestStream() throws {
        let factory = FakeTapFactory(streamChannels: [0: 2, 1: 8, 2: 2], failingStreams: [2])

        let taps = try TapAssembly.taps(forStreams: [2, 8, 2], using: factory)

        #expect(taps.count == 1)
        #expect(taps[0].stream == 1, "the widest stream was not chosen")
        #expect(taps[0].isDeviceBound)
        #expect(factory.globalTapRequests == 0)
    }

    // MARK: - The mixdown, last

    /// When no device-bound tap can be made at all, the stereo mixdown keeps
    /// audio working — losing everything past two channels, which is why it is
    /// the last thing tried rather than the first.
    @Test func aDeviceThatRefusesEveryStreamGetsTheMixdown() throws {
        let factory = FakeTapFactory(failingStreams: [0, 1])

        let taps = try TapAssembly.taps(forStreams: [2, 2], using: factory)

        #expect(taps.count == 1)
        #expect(!taps[0].isDeviceBound, "a mixdown was expected")
        #expect(factory.globalTapRequests == 1)
    }

    /// A device with one stream that cannot be tapped also falls through to the
    /// mixdown rather than failing.
    @Test func aSingleStreamThatFailsAlsoFallsBack() throws {
        let factory = FakeTapFactory(failingStreams: [0])

        let taps = try TapAssembly.taps(forStreams: [16], using: factory)

        #expect(taps.count == 1)
        #expect(!taps[0].isDeviceBound)
    }

    /// If even the mixdown is refused there is nothing left, and the error has
    /// to reach the caller: that is the one that means the permission was denied.
    @Test func nothingWorkingIsAnError() {
        let factory = FakeTapFactory(failingStreams: [0], globalTapWorks: false)

        #expect(throws: TapUnavailable.self) {
            try TapAssembly.taps(forStreams: [2], using: factory)
        }
    }

    // MARK: - Degenerate devices

    /// A stream reporting no channels disqualifies the per-stream path — a tap
    /// on it would contribute nothing while its neighbours were muted.
    @Test func aZeroWidthStreamDisqualifiesPerStreamTaps() throws {
        let factory = FakeTapFactory(streamChannels: [0: 2, 1: 0, 2: 2])

        let taps = try TapAssembly.taps(forStreams: [2, 0, 2], using: factory)

        #expect(taps.count == 1, "a device with an empty stream was tapped per stream")
    }

    /// A device reporting no streams at all still gets a tap: stream 0 is the
    /// only thing left to try, and the mixdown is behind it.
    @Test func aDeviceReportingNoStreamsIsStillTapped() throws {
        let factory = FakeTapFactory(streamChannels: [0: 2])

        let taps = try TapAssembly.taps(forStreams: [], using: factory)

        #expect(taps.count == 1)
        #expect(factory.requestedStreams == [0])
    }
}

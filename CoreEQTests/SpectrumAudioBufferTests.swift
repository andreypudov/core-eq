import Foundation
import Testing

/// The ring buffer between the render thread and the analyzer. Its index
/// arithmetic is the kind that looks right and wraps wrong, so it is worth
/// pinning down.
struct SpectrumAudioBufferTests {
    private func write(_ samples: [Float], to buffer: SpectrumAudioBuffer, channels: Int = 1) {
        samples.withUnsafeBufferPointer { pointer in
            buffer.write(
                interleaved: pointer.baseAddress!,
                frames: samples.count / channels,
                channels: channels
            )
        }
    }

    @Test func snapshotReturnsTheMostRecentSamplesInOrder() {
        let buffer = SpectrumAudioBuffer(capacity: 8)
        write([1, 2, 3, 4], to: buffer)

        var destination = [Float](repeating: 0, count: 4)
        let total = buffer.snapshot(into: &destination)

        #expect(destination == [1, 2, 3, 4])
        #expect(total == 4)
    }

    @Test func snapshotReadsAcrossTheWrapPoint() {
        let buffer = SpectrumAudioBuffer(capacity: 4)
        write([1, 2, 3, 4, 5, 6], to: buffer)  // wraps twice past the start

        var destination = [Float](repeating: 0, count: 4)
        #expect(buffer.snapshot(into: &destination) == 6)
        #expect(destination == [3, 4, 5, 6], "the snapshot must be the newest window, in order")
    }

    @Test func writingExactlyCapacityLeavesTheBufferOrdered() {
        let buffer = SpectrumAudioBuffer(capacity: 4)
        write([1, 2, 3, 4], to: buffer)

        var destination = [Float](repeating: 0, count: 4)
        _ = buffer.snapshot(into: &destination)
        #expect(destination == [1, 2, 3, 4])
    }

    @Test func interleavedChannelsAreSummedToMono() {
        let buffer = SpectrumAudioBuffer(capacity: 8)
        // Stereo: L/R pairs averaging to 1, 2, 3.
        write([0, 2, 1, 3, 2, 4], to: buffer, channels: 2)

        var destination = [Float](repeating: 0, count: 3)
        _ = buffer.snapshot(into: &destination)
        #expect(destination == [1, 2, 3])
    }

    @Test func totalWrittenAccumulatesAcrossWrites() {
        let buffer = SpectrumAudioBuffer(capacity: 16)
        write([1, 2, 3], to: buffer)
        write([4, 5], to: buffer)

        var destination = [Float](repeating: 0, count: 5)
        #expect(
            buffer.snapshot(into: &destination) == 5,
            "the running count is how the analyzer detects silence")
    }

    @Test func snapshotLargerThanCapacityIsClamped() {
        let buffer = SpectrumAudioBuffer(capacity: 4)
        write([1, 2, 3, 4], to: buffer)

        var destination = [Float](repeating: -1, count: 8)
        _ = buffer.snapshot(into: &destination)
        // Only `capacity` entries are filled; the rest keep their prior value.
        #expect(Array(destination.prefix(4)) == [1, 2, 3, 4])
    }

    @Test func zeroFrameWriteIsIgnored() {
        let buffer = SpectrumAudioBuffer(capacity: 4)
        let empty: [Float] = []
        empty.withUnsafeBufferPointer { pointer in
            buffer.write(
                interleaved: pointer.baseAddress ?? UnsafePointer(bitPattern: 0x1000)!, frames: 0,
                channels: 2)
        }

        var destination = [Float](repeating: 0, count: 2)
        #expect(buffer.snapshot(into: &destination) == 0)
    }
}

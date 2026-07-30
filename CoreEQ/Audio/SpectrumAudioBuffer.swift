import Foundation
import os

/// Single-producer / single-consumer ring buffer that carries a mono copy of
/// the audio the engine is playing out to the spectrum analyzer.
///
/// The producer is the Core Audio render thread, so `write` must never block:
/// it takes the lock only with `lockIfAvailable()` and drops the block if the
/// consumer happens to hold it (a dropped visualiser frame is harmless; the
/// audio path itself does not depend on this buffer). The consumer runs on the
/// main thread and may block briefly to copy a snapshot out.
final class SpectrumAudioBuffer {
    private let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var totalWritten: UInt64 = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Render thread. Sums the interleaved channels of one IO block to mono and
    /// appends them. Non-blocking: skips the block if the consumer holds the
    /// lock.
    func write(interleaved data: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard channels > 0, frames > 0, lock.lockIfAvailable() else { return }
        let scale = 1.0 / Float(channels)
        var w = writeIndex
        storage.withUnsafeMutableBufferPointer { ring in
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channels
                for channel in 0..<channels { sum += data[base + channel] }
                ring[w] = sum * scale
                w += 1
                if w == capacity { w = 0 }
            }
        }
        writeIndex = w
        totalWritten &+= UInt64(frames)
        lock.unlock()
    }

    /// Main thread. Copies the most recent `dest.count` samples in chronological
    /// order and returns the running total sample count, so the caller can tell
    /// whether new audio arrived since the last snapshot.
    func snapshot(into dest: inout [Float]) -> UInt64 {
        let count = min(dest.count, capacity)
        lock.lock()
        let total = totalWritten
        var index = ((writeIndex - count) % capacity + capacity) % capacity
        dest.withUnsafeMutableBufferPointer { out in
            storage.withUnsafeBufferPointer { ring in
                for i in 0..<count {
                    out[i] = ring[index]
                    index += 1
                    if index == capacity { index = 0 }
                }
            }
        }
        lock.unlock()
        return total
    }
}

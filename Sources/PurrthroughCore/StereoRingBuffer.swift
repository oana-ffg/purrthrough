import Synchronization

/// Single-producer, single-consumer stereo sample FIFO for realtime audio threads.
///
/// The input device's IO thread is the only writer and the output device's render
/// thread is the only reader. Neither side allocates, locks, or blocks. Counters
/// are monotonic frame totals; `Int` (64-bit) cannot overflow in practice.
public final class StereoRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writtenTotal = Atomic<Int>(0)
    private let readTotal = Atomic<Int>(0)
    /// Requested fill level to trim down to, applied by the reader (who owns `read`).
    private let trimRequest = Atomic<Int>(-1)
    private let droppedFrames = Atomic<Int>(0)
    private let missingFrames = Atomic<Int>(0)

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames written but not yet read. Safe to call from any thread.
    public var availableFrames: Int {
        let readCount = readTotal.load(ordering: .acquiring)
        return writtenTotal.load(ordering: .acquiring) - readCount
    }

    /// Total frames written so far, used as a liveness signal for the input side.
    public var totalWritten: Int { writtenTotal.load(ordering: .acquiring) }

    /// Total frames consumed so far, used as a liveness signal for the output side.
    public var totalRead: Int { readTotal.load(ordering: .acquiring) }

    /// Input frames discarded because the buffer was full.
    public var totalDropped: Int { droppedFrames.load(ordering: .relaxed) }

    /// Output frames rendered as silence because the buffer was empty.
    public var totalMissing: Int { missingFrames.load(ordering: .relaxed) }

    /// Producer only. Pass the same pointer twice for a mono source.
    /// Returns the number of frames stored; the rest are dropped and counted.
    @discardableResult
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Int {
        let writeCount = writtenTotal.load(ordering: .relaxed)
        let readCount = readTotal.load(ordering: .acquiring)
        let free = capacityFrames - (writeCount - readCount)
        let count = min(frames, free)
        if count < frames {
            droppedFrames.add(frames - count, ordering: .relaxed)
        }
        var position = writeCount % capacityFrames
        for frame in 0..<count {
            storage[position * 2] = left[frame]
            storage[position * 2 + 1] = right[frame]
            position += 1
            if position == capacityFrames { position = 0 }
        }
        writtenTotal.store(writeCount + count, ordering: .releasing)
        return count
    }

    /// Consumer only. Fills `frames` samples per channel, padding with silence on
    /// underrun. Returns how many frames came from the buffer.
    @discardableResult
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        applyPendingTrim()
        let readCount = readTotal.load(ordering: .relaxed)
        let writeCount = writtenTotal.load(ordering: .acquiring)
        let count = min(frames, writeCount - readCount)
        var position = readCount % capacityFrames
        for frame in 0..<count {
            left[frame] = storage[position * 2]
            right[frame] = storage[position * 2 + 1]
            position += 1
            if position == capacityFrames { position = 0 }
        }
        if count < frames {
            (left + count).update(repeating: 0, count: frames - count)
            (right + count).update(repeating: 0, count: frames - count)
            missingFrames.add(frames - count, ordering: .relaxed)
        }
        readTotal.store(readCount + count, ordering: .releasing)
        return count
    }

    /// Any thread. Asks the reader to discard the oldest audio until at most
    /// `fillFrames` remain, bounding latency after a stall or startup backlog.
    public func requestTrim(toFill fillFrames: Int) {
        trimRequest.store(max(0, fillFrames), ordering: .releasing)
    }

    private func applyPendingTrim() {
        let target = trimRequest.exchange(-1, ordering: .acquiring)
        guard target >= 0 else { return }
        let readCount = readTotal.load(ordering: .relaxed)
        let writeCount = writtenTotal.load(ordering: .acquiring)
        let excess = (writeCount - readCount) - target
        if excess > 0 {
            readTotal.store(readCount + excess, ordering: .releasing)
        }
    }
}

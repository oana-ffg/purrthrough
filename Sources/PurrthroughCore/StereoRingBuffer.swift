import Synchronization

/// Single-producer, single-consumer stereo sample FIFO for realtime audio threads.
///
/// The input device's IO thread is the only writer. The output device's render
/// thread is the reader; while no output is running, the owner may take its place
/// (see `discard(keepingNewest:)`). Neither side allocates, locks, or blocks. Counters
/// are monotonic frame totals; `Int` (64-bit) cannot overflow in practice.
///
/// After an underrun (and at startup) the reader re-primes: it plays silence until
/// `primeFrames` are queued, instead of stuttering on every short chunk.
public final class StereoRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writtenTotal = Atomic<Int>(0)
    private let readTotal = Atomic<Int>(0)
    /// Requested fill level to trim down to, applied by the reader (who owns `read`).
    private let trimRequest = Atomic<Int>(-1)
    private let droppedFrames = Atomic<Int>(0)
    private let missingFrames = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let largestWriteFrames = Atomic<Int>(0)
    private let largestReadFrames = Atomic<Int>(0)
    private let primeLevel = Atomic<Int>(0)
    /// Reader-owned. Atomic only because the render thread may change when the
    /// output device is rebuilt.
    private let priming = Atomic<Bool>(true)

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

    /// Output frames rendered as silence because the buffer ran dry mid-stream.
    /// Silence while priming at startup is not counted.
    public var totalMissing: Int { missingFrames.load(ordering: .relaxed) }

    /// Number of times the buffer ran dry mid-stream.
    public var totalUnderruns: Int { underrunCount.load(ordering: .relaxed) }

    /// Largest chunk the input side has delivered in one call.
    public var largestWrite: Int { largestWriteFrames.load(ordering: .relaxed) }

    /// Largest chunk the output side has requested in one call.
    public var largestRead: Int { largestReadFrames.load(ordering: .relaxed) }

    /// Forget the output's largest request, e.g. after switching to an output that
    /// pulls smaller chunks. Call only while no reader is running.
    public func resetLargestRead() {
        largestReadFrames.store(0, ordering: .relaxed)
    }

    /// Any thread. How much audio to queue before (re)starting playback.
    public func setPrimeLevel(_ frames: Int) {
        primeLevel.store(min(max(0, frames), capacityFrames), ordering: .relaxed)
    }

    /// Producer only. Pass the same pointer twice for a mono source.
    /// Returns the number of frames stored; the rest are dropped and counted.
    @discardableResult
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Int {
        if frames > largestWriteFrames.load(ordering: .relaxed) {
            largestWriteFrames.store(frames, ordering: .relaxed)
        }
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
    /// underrun or while priming. Returns how many frames came from the buffer.
    @discardableResult
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        if frames > largestReadFrames.load(ordering: .relaxed) {
            largestReadFrames.store(frames, ordering: .relaxed)
        }
        applyPendingTrim()
        let readCount = readTotal.load(ordering: .relaxed)
        let writeCount = writtenTotal.load(ordering: .acquiring)
        let queued = writeCount - readCount
        if priming.load(ordering: .relaxed) {
            // Never wait for more than the buffer can hold, or priming never ends.
            let needed = min(max(primeLevel.load(ordering: .relaxed), frames), capacityFrames)
            guard queued >= needed else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return 0
            }
            priming.store(false, ordering: .relaxed)
        }
        let count = min(frames, queued)
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
            underrunCount.add(1, ordering: .relaxed)
            priming.store(true, ordering: .relaxed)
        }
        readTotal.store(readCount + count, ordering: .releasing)
        return count
    }

    /// Any thread. Asks the reader to discard the oldest audio until at most
    /// `fillFrames` remain, bounding latency after a stall or startup backlog.
    /// Callers must keep `fillFrames` above the largest read, or the very next
    /// read underruns.
    public func requestTrim(toFill fillFrames: Int) {
        trimRequest.store(max(0, fillFrames), ordering: .releasing)
    }

    /// Consumer only: call it from the reader, or from another thread only while no
    /// reader is running. Discards the oldest audio until at most `frames` remain,
    /// for example to keep the input flowing while nothing plays it.
    public func discard(keepingNewest frames: Int) {
        let readCount = readTotal.load(ordering: .relaxed)
        let writeCount = writtenTotal.load(ordering: .acquiring)
        let excess = (writeCount - readCount) - max(0, frames)
        if excess > 0 {
            readTotal.store(readCount + excess, ordering: .releasing)
        }
    }

    private func applyPendingTrim() {
        let target = trimRequest.exchange(-1, ordering: .acquiring)
        guard target >= 0 else { return }
        discard(keepingNewest: target)
    }
}

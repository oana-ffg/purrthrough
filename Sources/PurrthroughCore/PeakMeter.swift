import Synchronization

/// The loudest input sample since the last look, shared with the realtime capture
/// thread without locking.
public final class PeakMeter: Sendable {
    /// Bit pattern of a non-negative `Float`. For non-negative floats (including
    /// +infinity) the bit patterns sort in the same order as the values, so an
    /// integer compare-and-swap can keep the maximum.
    private let bits = Atomic<UInt32>(0)

    public init() {}

    /// Realtime safe. Pass the same pointer twice for a mono source. NaN samples
    /// are ignored.
    public func record(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var peak: Float = 0
        // Compare each channel on its own: `max` with a NaN can return the NaN and
        // hide the other channel's sample.
        for frame in 0..<frames {
            let leftMagnitude = abs(left[frame])
            if leftMagnitude > peak { peak = leftMagnitude }
            let rightMagnitude = abs(right[frame])
            if rightMagnitude > peak { peak = rightMagnitude }
        }
        let candidate = peak.bitPattern
        var current = bits.load(ordering: .relaxed)
        while candidate > current {
            let (exchanged, original) = bits.compareExchange(
                expected: current, desired: candidate, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    /// Any thread. Returns the peak since the previous call and starts a new window.
    public func take() -> Float {
        Float(bitPattern: bits.exchange(0, ordering: .relaxed))
    }
}

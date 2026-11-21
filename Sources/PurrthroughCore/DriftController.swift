/// Keeps the FIFO between two independently clocked devices near a target fill.
///
/// The input and output devices never run at exactly the same rate (a USB card
/// and Bluetooth headphones can differ by hundreds of ppm). Instead of letting
/// the buffer slowly overflow or run dry, the output side plays slightly faster
/// or slower. The adjustment is capped well below audible pitch change.
public struct DriftController: Sendable {
    public struct Decision: Equatable, Sendable {
        /// Playback rate for the output side (1 = nominal).
        public var rate: Double
        /// When set, discard queued audio down to this many frames.
        public var trimToFrames: Int?
    }

    public private(set) var targetFrames: Int
    public private(set) var maximumFrames: Int
    public let maximumDeviation: Double
    private let gain: Double
    private let smoothing: Double
    private var smoothedFill: Double?

    /// - Parameters:
    ///   - targetFrames: Desired queued audio; covers device chunk-size jitter.
    ///   - maximumFrames: Above this, latency is cut immediately instead of slowly.
    ///   - maximumDeviation: Rate correction cap (0.005 = ±0.5%, inaudible).
    public init(targetFrames: Int, maximumFrames: Int, maximumDeviation: Double = 0.005,
                gain: Double = 0.01, smoothing: Double = 0.2) {
        precondition(targetFrames > 0 && maximumFrames > targetFrames)
        self.targetFrames = targetFrames
        self.maximumFrames = maximumFrames
        self.maximumDeviation = maximumDeviation
        self.gain = gain
        self.smoothing = smoothing
    }

    /// Call periodically (about 10 Hz) with the current FIFO fill.
    public mutating func update(fillFrames: Int) -> Decision {
        if fillFrames > maximumFrames {
            // A stall or startup backlog: drop it now and restart smoothing.
            smoothedFill = Double(targetFrames)
            return Decision(rate: 1, trimToFrames: targetFrames)
        }
        let fill = Double(fillFrames)
        let smoothed = smoothedFill.map { $0 + smoothing * (fill - $0) } ?? fill
        smoothedFill = smoothed
        let error = (smoothed - Double(targetFrames)) / Double(targetFrames)
        let correction = min(max(gain * error, -maximumDeviation), maximumDeviation)
        return Decision(rate: 1 + correction, trimToFrames: nil)
    }

    /// Adopt a new plan, e.g. once a device turns out to move larger chunks.
    public mutating func retarget(_ plan: LatencyPlan) {
        precondition(plan.targetFrames > 0 && plan.maximumFrames > plan.targetFrames)
        targetFrames = plan.targetFrames
        maximumFrames = plan.maximumFrames
    }

    /// Forget history, e.g. after the output device changed.
    public mutating func reset() {
        smoothedFill = nil
    }
}

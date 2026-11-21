import Synchronization

/// Linear playback gain shared with the realtime render thread without locking.
public final class PlaybackGain: Sendable {
    /// 2 = +6 dB, enough to lift a quiet line-level source.
    public static let maximum: Float = 2

    private let bits: Atomic<UInt32>

    public init(_ value: Float) {
        bits = Atomic(Self.clamped(value).bitPattern)
    }

    public var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(Self.clamped(newValue).bitPattern, ordering: .relaxed) }
    }

    /// Realtime safe. Scales both channels in place.
    public func apply(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let gain = value
        guard gain != 1 else { return }
        for frame in 0..<frames {
            left[frame] *= gain
            right[frame] *= gain
        }
    }

    private static func clamped(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), maximum) : 1
    }
}

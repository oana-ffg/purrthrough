import Foundation
import Synchronization

/// Linear playback gain shared with the realtime render thread without locking.
///
/// Boosting a quiet source can push peaks past full scale. Above `limiterKnee`,
/// samples are compressed smoothly towards ±1 instead of clipping hard.
public final class PlaybackGain: Sendable {
    /// 4 = +12 dB, enough to lift a weak line-level source such as a monitor's
    /// headphone jack.
    public static let maximum: Float = 4
    static let limiterKnee: Float = 0.8

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
        if gain < 1 {
            for frame in 0..<frames {
                left[frame] *= gain
                right[frame] *= gain
            }
            return
        }
        for frame in 0..<frames {
            left[frame] = Self.limit(left[frame] * gain)
            right[frame] = Self.limit(right[frame] * gain)
        }
    }

    /// Identity below the knee; above it, approaches ±1 without ever exceeding it.
    static func limit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let headroom = 1 - limiterKnee
        let compressed = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
        return sample < 0 ? -compressed : compressed
    }

    private static func clamped(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), maximum) : 1
    }
}

import Foundation

/// Decides whether to hold the output device, based on how long the input has
/// been silent.
///
/// An open output stream keeps a Bluetooth headset busy even when it carries only
/// silence, so multipoint headphones refuse to switch to another device (a phone,
/// say) while this Mac holds them. Releasing the output after a stretch of silence
/// and taking it back on the first sound avoids that.
///
/// The gate starts closed, so launching, waking or reconnecting while the source is
/// quiet never grabs the output.
public struct SilenceGate: Sendable {
    /// −50 dBFS. Far above a line input's own noise (a USB line input with its
    /// source silent peaks at about −67 dBFS) and far below quiet speech or music.
    public static let defaultThreshold: Float = 0.003_162

    /// Input peak at or above which the input counts as sounding.
    public let threshold: Float
    /// Silence after which the output is released; `nil` always holds it.
    public var releaseAfter: TimeInterval?
    private var lastSound = -TimeInterval.infinity

    public init(releaseAfter: TimeInterval?, threshold: Float = defaultThreshold) {
        self.releaseAfter = releaseAfter
        self.threshold = threshold
    }

    /// Call periodically with the loudest input sample since the previous call.
    public mutating func record(peak: Float, at now: TimeInterval) {
        if peak >= threshold { lastSound = now }
    }

    /// Whether the output should be held at `now`.
    public func holdsOutput(at now: TimeInterval) -> Bool {
        guard let releaseAfter else { return true }
        return now - lastSound < releaseAfter
    }
}

/// How much audio to keep queued between the two devices.
///
/// The queue must cover the largest chunk the output pulls at once plus the largest
/// chunk the input delivers at once, or playback runs dry between them. Bluetooth
/// outputs often pull thousands of frames per request, far more than a USB input
/// delivers, so the target grows to fit what the devices actually do.
public struct LatencyPlan: Equatable, Sendable {
    public var targetFrames: Int
    public var maximumFrames: Int

    public static let baseLatency = 0.04
    public static let reserveLatency = 0.01
    public static let backlogAllowance = 0.2

    public init(sampleRate: Double, largestRead: Int, largestWrite: Int) {
        let base = Int(sampleRate * Self.baseLatency)
        let reserve = Int(sampleRate * Self.reserveLatency)
        targetFrames = max(base, largestRead + largestWrite + reserve)
        maximumFrames = targetFrames + Int(sampleRate * Self.backlogAllowance)
    }
}

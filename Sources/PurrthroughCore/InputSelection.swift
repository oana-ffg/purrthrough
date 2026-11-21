/// A CoreAudio input device, reduced to what selection and the menu need.
public struct InputDeviceInfo: Equatable, Sendable {
    public var uid: String
    public var name: String
    public var isBluetooth: Bool

    public init(uid: String, name: String, isBluetooth: Bool) {
        self.uid = uid
        self.name = name
        self.isBluetooth = isBluetooth
    }
}

public enum InputSelection {
    /// The device to play through, or nil when none is usable right now.
    ///
    /// A saved choice is binding: if that device is unplugged we wait for it
    /// rather than silently switching to some other microphone. Without a saved
    /// choice we only auto-pick an obvious line input. Bluetooth inputs are never
    /// auto-picked, because opening a headset microphone switches the headset
    /// into low-quality call mode for its output too.
    public static func choose(savedUID: String?, available: [InputDeviceInfo]) -> InputDeviceInfo? {
        if let savedUID {
            return available.first { $0.uid == savedUID }
        }
        return available.first { !$0.isBluetooth && $0.name.lowercased().contains("line") }
    }
}

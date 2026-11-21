import CoreAudio
import Foundation
import os

struct AudioHardwareError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "\(operation) failed (CoreAudio \(status))" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw AudioHardwareError(operation: operation(), status: status) }
}

/// Thin, synchronous wrappers over the CoreAudio HAL property API.
enum AudioHardware {
    static func defaultOutputDevice() throws -> AudioDeviceID {
        try systemProperty(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func inputDevices() throws -> [(id: AudioDeviceID, info: InputDeviceInfo)] {
        try allDevices().compactMap { id in
            guard try channelCount(of: id, scope: kAudioObjectPropertyScopeInput) > 0 else { return nil }
            let info = InputDeviceInfo(uid: try uid(of: id), name: try name(of: id), isBluetooth: try isBluetooth(id))
            return (id, info)
        }
    }

    static func name(of device: AudioDeviceID) throws -> String {
        try stringProperty(device, kAudioObjectPropertyName)
    }

    static func uid(of device: AudioDeviceID) throws -> String {
        try stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    static func nominalSampleRate(of device: AudioDeviceID) throws -> Double {
        let rate: Float64 = try property(device, kAudioDevicePropertyNominalSampleRate)
        return rate
    }

    static func isBluetooth(_ device: AudioDeviceID) throws -> Bool {
        let transport: UInt32 = try property(device, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Reading stream configuration size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "Reading stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func allDevices() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "Listing audio devices")
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices), "Listing audio devices")
        return devices
    }

    private static func systemProperty<T>(_ selector: AudioObjectPropertySelector) throws -> T {
        try property(AudioObjectID(kAudioObjectSystemObject), selector)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value), "Reading audio property \(selector)")
        return value.pointee
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Reading audio name \(selector)")
        guard let value else { throw AudioHardwareError(operation: "Reading audio name \(selector)", status: -1) }
        return value.takeRetainedValue() as String
    }
}

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> Self {
        Self(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func input(_ selector: AudioObjectPropertySelector) -> Self {
        Self(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Calls `handler` on the main queue whenever one of the given HAL properties
/// changes. Listening stops when the observer is released. A registration
/// failure throws, and any listeners already added are removed by deinit.
final class AudioPropertyObserver {
    private let object: AudioObjectID
    private var addresses: [AudioObjectPropertyAddress]
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, addresses: [AudioObjectPropertyAddress], handler: @escaping @MainActor () -> Void) throws {
        self.object = object
        self.addresses = addresses
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        for index in self.addresses.indices {
            try check(AudioObjectAddPropertyListenerBlock(object, &self.addresses[index], .main, block),
                      "Watching audio property \(addresses[index].mSelector)")
        }
    }

    deinit {
        for index in addresses.indices {
            let status = AudioObjectRemovePropertyListenerBlock(object, &addresses[index], .main, block)
            if status != noErr {
                // Expected when the device was unplugged; logged for diagnosis.
                Logger(subsystem: "com.firefungames.purrthrough", category: "hardware")
                    .debug("Listener removal returned \(status) for selector \(self.addresses[index].mSelector)")
            }
        }
    }
}

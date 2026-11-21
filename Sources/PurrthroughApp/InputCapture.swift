import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Captures one input device with an AUHAL unit and pushes its audio into the FIFO.
///
/// Only the chosen device is opened. Purrthrough never touches the system default
/// input (often a Bluetooth headset microphone), because opening a headset
/// microphone forces the headset into low-quality call mode.
final class InputCapture: @unchecked Sendable {
    private(set) var sampleRate: Double = 0
    private let unit: AudioUnit
    private let ring: StereoRingBuffer
    private let maximumFrames: UInt32 = 8192
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let renderFailures = Atomic<Int>(0)

    init(device: AudioDeviceID, ring: StereoRingBuffer) throws {
        let deviceChannels = try AudioHardware.channelCount(of: device, scope: kAudioObjectPropertyScopeInput)
        let channels = min(max(deviceChannels, 1), 2)
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioHardwareError(operation: "Finding the HAL audio unit", status: -1)
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Creating the input audio unit")
        unit = instance!
        self.ring = ring
        bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            let bytes = Int(maximumFrames) * MemoryLayout<Float>.size
            bufferList[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes),
                                            mData: UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16))
        }
        // Fully initialized from here on, so deinit releases everything if configuration fails.
        try configure(device: device, channels: UInt32(channels))
    }

    deinit {
        // The owner stops capture before releasing it (see `stop()`); this is the
        // fallback for a failed initialization. The callback never retains `self`,
        // so deinit can only run on the owner's thread, never inside a callback.
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for buffer in bufferList {
            buffer.mData?.deallocate()
        }
        free(bufferList.unsafeMutablePointer)
    }

    func start() throws {
        try check(AudioOutputUnitStart(unit), "Starting capture")
    }

    /// Stops the device IO. Returns after any in-flight callback has finished, so
    /// the owner may release this object afterwards. Idempotent.
    func stop() {
        AudioOutputUnitStop(unit)
    }

    /// Render errors seen on the IO thread since the last call.
    func takeRenderFailures() -> Int {
        renderFailures.exchange(0, ordering: .relaxed)
    }

    private func configure(device: AudioDeviceID, channels: UInt32) throws {
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try setProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, "Enabling input")
        try setProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, "Disabling output")
        var deviceID = device
        try setProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                        "Selecting the input device")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                       &hardware, &size), "Reading the input format")
        sampleRate = hardware.mSampleRate
        // The HAL unit cannot resample input. Keep the device rate and let the
        // output engine convert. Deinterleaved Float32, one or two channels.
        var client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
        try setProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, "Setting the capture format")
        var maximum = maximumFrames
        try setProperty(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum,
                        "Setting the capture slice size")

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                // No retain/release on the realtime thread: a temporary strong
                // reference could make this callback drop the last one and run
                // deinit (stopping and disposing the unit) from inside itself.
                Unmanaged<InputCapture>.fromOpaque(refCon)._withUnsafeGuaranteedRef {
                    $0.capture(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
                }
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try setProperty(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                        "Installing the capture callback")
        try check(AudioUnitInitialize(unit), "Initializing the input audio unit")
    }

    /// Runs on the device's realtime IO thread: no allocation, locks or logging.
    private func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         timeStamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames <= maximumFrames else {
            renderFailures.add(1, ordering: .relaxed)
            return kAudioUnitErr_TooManyFramesToProcess
        }
        for index in 0..<bufferList.count {
            bufferList[index].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            renderFailures.add(1, ordering: .relaxed)
            return status
        }
        // A mono device feeds the same samples to both ears.
        let left = bufferList[0].mData!.assumingMemoryBound(to: Float.self)
        let right = bufferList[bufferList.count - 1].mData!.assumingMemoryBound(to: Float.self)
        ring.write(left: left, right: right, frames: Int(frames))
        return noErr
    }

    private func setProperty<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
                                _ value: inout T, _ operation: String) throws {
        try check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), operation)
    }
}

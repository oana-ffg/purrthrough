import AudioToolbox
import AVFoundation
import CoreAudio

/// Plays the FIFO on one output device through AVAudioEngine.
///
/// The engine converts from the input's sample rate to whatever the device runs
/// at (e.g. 48 kHz USB in, 44.1 kHz Bluetooth out). A varispeed unit lets the
/// drift controller nudge consumption to match the input device's real clock.
///
/// Never access `engine.inputNode`: doing so opens the default input device,
/// which may be a Bluetooth headset microphone, and that forces the headset into
/// call mode.
final class OutputPlayer {
    let deviceName: String
    private let engine = AVAudioEngine()
    private let varispeed = AVAudioUnitVarispeed()
    private let source: AVAudioSourceNode
    private var configurationObserver: NSObjectProtocol?

    init(device: AudioDeviceID, sampleRate: Double, ring: StereoRingBuffer, gain: PlaybackGain,
         onConfigurationChange: @escaping @MainActor () -> Void) throws {
        deviceName = try AudioHardware.name(of: device)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AudioHardwareError(operation: "Creating a \(sampleRate) Hz stereo format", status: -1)
        }
        // Runs on the output device's realtime thread.
        source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            if ring.read(left: left, right: right, frames: Int(frameCount)) == 0 {
                isSilence.pointee = true
            } else {
                gain.apply(left: left, right: right, frames: Int(frameCount))
            }
            return noErr
        }

        // Pin the engine to the device we chose so a later default change is an
        // explicit rebuild rather than an implicit engine reconfiguration.
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw AudioHardwareError(operation: "Opening the output audio unit", status: -1)
        }
        var deviceID = device
        try check(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting the output device")

        engine.attach(source)
        engine.attach(varispeed)
        engine.connect(source, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { onConfigurationChange() }
        }
        engine.prepare()
        try engine.start()
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.stop()
    }

    var isRunning: Bool { engine.isRunning }

    /// Stops rendering; returns once the render thread no longer calls the source.
    func stop() {
        engine.stop()
    }

    func setRate(_ rate: Double) {
        varispeed.rate = Float(rate)
    }
}

import AppKit
import AVFoundation
import CoreAudio
import os

enum PlaythroughStatus: Equatable {
    case off
    case needsMicrophoneAccess
    case noInputChosen
    case waitingForInput(String)
    case playing(input: String, output: String)
    case failed(String)
}

/// Owns the capture → FIFO → playback pipeline and keeps it matched to the
/// user's choices and the current hardware. Every change funnels into
/// `reconcile()`, which is idempotent.
@MainActor
final class PlaythroughController {
    private enum Key {
        static let enabled = "enabled"
        static let inputUID = "inputUID"
        static let inputName = "inputName"
        static let volume = "volume"
    }

    private static let targetLatency = 0.04
    private static let maximumLatency = 0.25
    private static let stallTimeout: TimeInterval = 2
    private static let retryDelay: TimeInterval = 3

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.firefungames.purrthrough", category: "playthrough")

    private(set) var status: PlaythroughStatus = .off {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    var onStatusChange: (() -> Void)?

    private var ring: StereoRingBuffer?
    private var capture: InputCapture?
    private var captureUID: String?
    private var player: OutputPlayer?
    private var playerDevice: AudioDeviceID?
    private var drift: DriftController?

    private var hardwareObserver: AudioPropertyObserver?
    private var inputObserver: AudioPropertyObserver?
    private var wakeObserver: NSObjectProtocol?
    private var tickTimer: Timer?
    private var retryTimer: Timer?
    private var lastProgress = (written: 0, read: 0, at: Date())
    private var ticks = 0

    /// Playback volume, 0...PlaybackGain.maximum (1 = unchanged). Applies instantly.
    private lazy var gain = PlaybackGain((defaults.object(forKey: Key.volume) as? NSNumber)?.floatValue ?? 1)

    var volume: Float {
        get { gain.value }
        set {
            gain.value = newValue
            defaults.set(gain.value, forKey: Key.volume)
        }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.enabled)
            reconcile()
        }
    }

    var selectedInputUID: String? { defaults.string(forKey: Key.inputUID) }

    func start() {
        do {
            hardwareObserver = try AudioPropertyObserver(
                object: AudioObjectID(kAudioObjectSystemObject),
                selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
            ) { [weak self] in self?.reconcile() }
        } catch {
            fail("Cannot watch audio devices: \(error.localizedDescription)")
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "wake from sleep") }
        }
        reconcile()
    }

    func selectInput(_ device: InputDeviceInfo) {
        defaults.set(device.uid, forKey: Key.inputUID)
        defaults.set(device.name, forKey: Key.inputName)
        reconcile()
    }

    func availableInputs() throws -> [InputDeviceInfo] {
        try AudioHardware.inputDevices().map(\.info)
    }

    func stop() {
        teardown()
        hardwareObserver = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Brings the running pipeline in line with settings and hardware.
    func reconcile() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard isEnabled else {
            teardown()
            status = .off
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            return
        default:
            teardown()
            status = .needsMicrophoneAccess
            return
        }
        do {
            try reconcileHardware()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func reconcileHardware() throws {
        let inputs = try AudioHardware.inputDevices()
        let saved = selectedInputUID
        guard let chosen = InputSelection.choose(savedUID: saved, available: inputs.map(\.info)),
              let inputID = inputs.first(where: { $0.info.uid == chosen.uid })?.id else {
            teardown()
            status = saved == nil ? .noInputChosen : .waitingForInput(defaults.string(forKey: Key.inputName) ?? "the chosen input")
            return
        }
        if saved == nil {
            // Remember the auto-picked line input so unplugging it waits for it.
            selectInput(chosen)
            return
        }
        if captureUID != chosen.uid || capture == nil {
            try startCapture(device: inputID, uid: chosen.uid)
        }
        let outputID = try AudioHardware.defaultOutputDevice()
        if player == nil || playerDevice != outputID || player?.isRunning == false {
            try startPlayer(device: outputID)
        }
        guard let player else { return }
        status = .playing(input: chosen.name, output: player.deviceName)
    }

    private func startCapture(device: AudioDeviceID, uid: String) throws {
        teardown()
        let rate = try AudioHardware.nominalSampleRate(of: device)
        let ring = StereoRingBuffer(capacityFrames: Int(rate))
        let capture = try InputCapture(device: device, ring: ring)
        guard capture.sampleRate == rate else {
            throw AudioHardwareError(operation: "Matching the input rate (\(capture.sampleRate) vs \(rate) Hz)", status: -1)
        }
        self.ring = ring
        drift = DriftController(targetFrames: Int(rate * Self.targetLatency),
                                maximumFrames: Int(rate * Self.maximumLatency))
        inputObserver = try AudioPropertyObserver(
            object: device,
            selectors: [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive,
                        kAudioDevicePropertyStreamConfiguration]
        ) { [weak self] in self?.restart(reason: "input device changed") }
        try capture.start()
        self.capture = capture
        captureUID = uid
        log.info("Capturing \(uid, privacy: .public) at \(rate) Hz")
        startTicking()
    }

    private func startPlayer(device: AudioDeviceID) throws {
        guard let ring, let capture else { return }
        player = nil
        playerDevice = nil
        let player = try OutputPlayer(device: device, sampleRate: capture.sampleRate, ring: ring, gain: gain) { [weak self] in
            self?.restartOutput(reason: "output configuration changed")
        }
        self.player = player
        playerDevice = device
        drift?.reset()
        if let drift { ring.requestTrim(toFill: drift.targetFrames) }
        resetProgress()
        log.info("Playing to \(player.deviceName, privacy: .public)")
    }

    private func startTicking() {
        tickTimer?.invalidate()
        resetProgress()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard let ring, let player, var drift else { return }
        let decision = drift.update(fillFrames: ring.availableFrames)
        self.drift = drift
        if let trim = decision.trimToFrames { ring.requestTrim(toFill: trim) }
        player.setRate(decision.rate)

        if let failures = capture?.takeRenderFailures(), failures > 0 {
            log.error("Input render failed \(failures) times")
        }
        ticks += 1
        if ticks % 100 == 0 {
            log.info("""
                fill \(ring.availableFrames) frames, rate \(decision.rate, format: .fixed(precision: 5)), \
                dropped \(ring.totalDropped), missing \(ring.totalMissing)
                """)
        }
        let now = Date()
        let written = ring.totalWritten
        let read = ring.totalRead
        if written != lastProgress.written && read != lastProgress.read {
            lastProgress = (written, read, now)
        } else if now.timeIntervalSince(lastProgress.at) > Self.stallTimeout {
            // A device stopped delivering or consuming audio without telling us.
            if written == lastProgress.written {
                restart(reason: "input stalled")
            } else {
                restartOutput(reason: "output stalled")
            }
        }
    }

    private func resetProgress() {
        lastProgress = (ring?.totalWritten ?? 0, ring?.totalRead ?? 0, Date())
    }

    private func restartOutput(reason: String) {
        log.notice("Restarting output: \(reason, privacy: .public)")
        player = nil
        playerDevice = nil
        reconcile()
    }

    private func restart(reason: String) {
        log.notice("Restarting playthrough: \(reason, privacy: .public)")
        teardown()
        reconcile()
    }

    private func teardown() {
        tickTimer?.invalidate()
        tickTimer = nil
        player = nil
        playerDevice = nil
        capture = nil
        captureUID = nil
        inputObserver = nil
        ring = nil
        drift = nil
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        teardown()
        status = .failed(message)
        // Devices often settle a moment after hot-plug or wake; try again.
        let timer = Timer(timeInterval: Self.retryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }
}

import AppKit
import AVFoundation
import CoreAudio
import os

enum PlaythroughStatus: Equatable {
    case off
    case awaitingMicrophoneAccess
    case needsMicrophoneAccess
    case noInputChosen
    case waitingForInput(String)
    /// Capturing, but the output is released because the input is silent.
    case silent(input: String)
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
        static let releaseWhenSilentAfter = "releaseWhenSilentAfter"
    }

    static let defaultReleaseWhenSilentAfter: TimeInterval = 30

    /// Bluetooth outputs can take a couple of seconds to start pulling audio.
    private static let stallTimeout: TimeInterval = 5
    private static let retryDelay: TimeInterval = 3
    /// Lowest device rate accepted; anything below is a device mid-transition.
    private static let minimumSampleRate = 8_000.0

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.firefungames.purrthrough", category: "playthrough")

    private(set) var status: PlaythroughStatus = .off {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    var onStatusChange: (() -> Void)?

    private var ring: StereoRingBuffer?
    /// Outlives each capture, like the gate it feeds.
    private let peakMeter = PeakMeter()
    private lazy var silenceGate = SilenceGate(releaseAfter: Self.validReleaseAfter(
        (defaults.object(forKey: Key.releaseWhenSilentAfter) as? NSNumber)?.doubleValue
            ?? Self.defaultReleaseWhenSilentAfter))
    /// Loudest input since the last periodic log line.
    private var loggedPeak: Float = 0
    private var capture: InputCapture?
    private var captureUID: String?
    private var captureDevice: AudioDeviceID?
    /// Bumped whenever the capture or player is replaced. Callbacks already queued
    /// on the main queue by a replaced object carry an old generation and are ignored.
    private var captureGeneration = 0
    private var outputGeneration = 0
    private var player: OutputPlayer?
    private var playerDevice: AudioDeviceID?
    private var drift: DriftController?
    private var plan: LatencyPlan?
    private var sampleRate: Double = 0

    private var hardwareObserver: AudioPropertyObserver?
    private var inputObserver: AudioPropertyObserver?
    private var wakeObserver: NSObjectProtocol?
    private var tickTimer: Timer?
    private var retryTimer: Timer?
    /// Uptime-based so clock changes can neither hide nor fake a stall.
    private var lastProgress = (written: 0, read: 0, at: ProcessInfo.processInfo.systemUptime)
    private var isRequestingAccess = false
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

    /// Seconds of input silence after which the output device is released, so
    /// multipoint headphones can switch to another device; `nil` never releases it.
    var releaseWhenSilentAfter: TimeInterval? {
        get { silenceGate.releaseAfter }
        set {
            let value = Self.validReleaseAfter(newValue ?? 0)
            silenceGate.releaseAfter = value
            defaults.set(value ?? 0, forKey: Key.releaseWhenSilentAfter)
            reconcile()
        }
    }

    /// Stored as seconds; zero (or anything not positive) means never.
    private static func validReleaseAfter(_ seconds: TimeInterval) -> TimeInterval? {
        seconds.isFinite && seconds > 0 ? seconds : nil
    }

    var selectedInputUID: String? { defaults.string(forKey: Key.inputUID) }

    func start() {
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
        retryTimer?.invalidate()
        retryTimer = nil
        teardown()
        hardwareObserver = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
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
            teardown()
            status = .awaitingMicrophoneAccess
            guard !isRequestingAccess else { return }
            isRequestingAccess = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    self?.isRequestingAccess = false
                    self?.reconcile()
                }
            }
            return
        default:
            // Re-checked whenever the menu opens, so granting access in System
            // Settings takes effect without restarting Purrthrough.
            teardown()
            status = .needsMicrophoneAccess
            return
        }
        do {
            try ensureHardwareObserver()
            try reconcileHardware()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Device and default-output changes drive everything else, so playback must
    /// never run without this observer. Installing it is retried with the rest.
    private func ensureHardwareObserver() throws {
        guard hardwareObserver == nil else { return }
        hardwareObserver = try AudioPropertyObserver(
            object: AudioObjectID(kAudioObjectSystemObject),
            addresses: [.global(kAudioHardwarePropertyDevices), .global(kAudioHardwarePropertyDefaultOutputDevice)]
        ) { [weak self] in self?.reconcile() }
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
        // A re-enumerated USB device keeps its UID but gets a new device ID.
        if captureUID != chosen.uid || captureDevice != inputID || capture == nil {
            try startCapture(device: inputID, uid: chosen.uid)
        }
        guard silenceGate.holdsOutput(at: ProcessInfo.processInfo.systemUptime) else {
            if player != nil {
                log.info("Input silent; releasing the output")
                stopPlayer()
            }
            status = .silent(input: chosen.name)
            return
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
        guard rate.isFinite, rate >= Self.minimumSampleRate else {
            throw AudioHardwareError(operation: "Reading a usable input sample rate (got \(rate) Hz)", status: -1)
        }
        // At least a second of audio, and never less than a large Bluetooth pull.
        let ring = StereoRingBuffer(capacityFrames: max(Int(rate), 16_384))
        let capture = try InputCapture(device: device, ring: ring, meter: peakMeter)
        guard capture.sampleRate == rate else {
            throw AudioHardwareError(operation: "Matching the input rate (\(capture.sampleRate) vs \(rate) Hz)", status: -1)
        }
        let plan = LatencyPlan(sampleRate: rate, largestRead: 0, largestWrite: 0)
        ring.setPrimeLevel(plan.targetFrames)
        self.ring = ring
        self.plan = plan
        sampleRate = rate
        drift = DriftController(targetFrames: plan.targetFrames, maximumFrames: plan.maximumFrames)
        let generation = captureGeneration
        inputObserver = try AudioPropertyObserver(
            object: device,
            addresses: [.global(kAudioDevicePropertyNominalSampleRate), .global(kAudioDevicePropertyDeviceIsAlive),
                        .input(kAudioDevicePropertyStreamConfiguration)]
        ) { [weak self] in
            guard let self, captureGeneration == generation else { return }
            restart(reason: "input device changed")
        }
        try capture.start()
        self.capture = capture
        captureUID = uid
        captureDevice = device
        log.info("Capturing \(uid, privacy: .public) at \(rate) Hz")
        startTicking()
    }

    private func startPlayer(device: AudioDeviceID) throws {
        guard let ring, let capture else { return }
        stopPlayer()
        // The new output may pull smaller chunks; relearn its size.
        ring.resetLargestRead()
        let generation = outputGeneration
        let player = try OutputPlayer(device: device, sampleRate: capture.sampleRate, ring: ring, gain: gain) { [weak self] in
            guard let self, outputGeneration == generation else { return }
            restartOutput(reason: "output configuration changed")
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
        guard let ring, var drift else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let peak = peakMeter.take()
        loggedPeak = max(loggedPeak, peak)
        silenceGate.record(peak: peak, at: now)
        // reconcile() keeps a player exactly while the gate holds the output, so a
        // mismatch means the input just fell silent or came back.
        if silenceGate.holdsOutput(at: now) != (player != nil) {
            reconcile()
            return
        }
        // Grow the queue once a device turns out to move bigger chunks.
        let updated = LatencyPlan(sampleRate: sampleRate, largestRead: ring.largestRead, largestWrite: ring.largestWrite)
        if updated != plan {
            plan = updated
            drift.retarget(updated)
            ring.setPrimeLevel(updated.targetFrames)
            log.info("Latency target \(updated.targetFrames) frames (largest read \(ring.largestRead), write \(ring.largestWrite))")
        }
        var rate: Double?
        if let player {
            let decision = drift.update(fillFrames: ring.availableFrames)
            if let trim = decision.trimToFrames { ring.requestTrim(toFill: trim) }
            player.setRate(decision.rate)
            rate = decision.rate
        } else {
            // Nothing reads the FIFO while the output is released; keep it from
            // overflowing so the newest audio is ready when sound returns.
            ring.discard(keepingNewest: drift.targetFrames)
        }
        self.drift = drift

        if let failures = capture?.takeRenderFailures(), failures > 0 {
            log.error("Input render failed \(failures) times")
        }
        ticks += 1
        if ticks % 100 == 0 {
            logStatistics(ring: ring, targetFrames: drift.targetFrames, rate: rate)
        }
        let written = ring.totalWritten
        let read = ring.totalRead
        let inputMoved = written != lastProgress.written
        // A released output is not expected to read anything.
        let outputMoved = player == nil || read != lastProgress.read
        if inputMoved && outputMoved {
            lastProgress = (written, read, now)
        } else if now - lastProgress.at > Self.stallTimeout {
            // A device stopped delivering or consuming audio without telling us.
            if inputMoved {
                restartOutput(reason: "output stalled")
            } else {
                restart(reason: "input stalled")
            }
        }
    }

    private func logStatistics(ring: StereoRingBuffer, targetFrames: Int, rate: Double?) {
        // The input peak shows where the source's noise floor sits relative to the
        // silence threshold.
        let peakDecibels = 20 * log10(Double(max(loggedPeak, 1e-7)))
        loggedPeak = 0
        let output = rate.map { String(format: "rate %.5f", $0) } ?? "output released"
        log.info("""
            input peak \(peakDecibels, format: .fixed(precision: 1)) dBFS, \(output, privacy: .public), \
            fill \(ring.availableFrames)/\(targetFrames) frames, \
            underruns \(ring.totalUnderruns), missing \(ring.totalMissing), dropped \(ring.totalDropped)
            """)
    }

    private func resetProgress() {
        lastProgress = (ring?.totalWritten ?? 0, ring?.totalRead ?? 0, ProcessInfo.processInfo.systemUptime)
    }

    private func restartOutput(reason: String) {
        log.notice("Restarting output: \(reason, privacy: .public)")
        stopPlayer()
        reconcile()
    }

    private func restart(reason: String) {
        log.notice("Restarting playthrough: \(reason, privacy: .public)")
        teardown()
        reconcile()
    }

    /// Stop each realtime side explicitly before releasing it, so no callback can
    /// still be running when its objects go away.
    private func teardown() {
        tickTimer?.invalidate()
        tickTimer = nil
        stopPlayer()
        capture?.stop()
        capture = nil
        captureUID = nil
        captureDevice = nil
        captureGeneration += 1
        inputObserver = nil
        ring = nil
        drift = nil
        plan = nil
    }

    private func stopPlayer() {
        player?.stop()
        player = nil
        playerDevice = nil
        outputGeneration += 1
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

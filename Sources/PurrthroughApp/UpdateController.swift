import AppKit
import Sparkle

/// Signed Sparkle updates from GitHub Releases, with a single user-facing switch.
///
/// With automatic updates on, Sparkle checks daily, downloads in the background
/// and installs right away. Purrthrough relaunches by itself and resumes playing
/// within a couple of seconds, so there is no reason to hold an update until quit.
/// With them off, Purrthrough makes no network requests at all.
@MainActor
final class UpdateController: NSObject, @preconcurrency SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    /// Called with a message when an update cycle fails, and with nil once one succeeds.
    var onIssueChange: ((String?) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        let updater = controller.updater
        // Sparkle stores checking and downloading separately, and its update dialog
        // offers a checkbox for downloading only. Keep them as one preference so
        // "off" really means no background checks. A mixed state resolves to off.
        updatesAutomatically = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        // Sparkle forwards these from UserDefaults KVO, which can fire on a
        // background thread when preferences change outside the app.
        let relink: @Sendable (Bool) -> Void = { [weak self] enabled in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.link(enabled) }
            } else {
                Task { @MainActor in self?.link(enabled) }
            }
        }
        observations = [
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { _, change in
                if let enabled = change.newValue { relink(enabled) }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { _, change in
                if let enabled = change.newValue { relink(enabled) }
            },
        ]
        do { try updater.start() }
        catch { onIssueChange?("Automatic updates could not start: \(error.localizedDescription)") }
    }

    var updatesAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { link(newValue) }
    }

    /// False while an update is already in progress or the updater failed to start.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func link(_ enabled: Bool) {
        let updater = controller.updater
        // Assign only on change: each assignment re-enters the observers above.
        if updater.automaticallyChecksForUpdates != enabled { updater.automaticallyChecksForUpdates = enabled }
        if updater.automaticallyDownloadsUpdates != enabled { updater.automaticallyDownloadsUpdates = enabled }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle requires the delegate to return before the handler runs.
        Task { @MainActor in installHandler() }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error else {
            onIssueChange?(nil)
            return
        }
        let updateError = error as NSError
        // Sparkle reports these normal outcomes as errors.
        if updateError.domain == SUSparkleErrorDomain,
           updateError.code == SUError.noUpdateError.rawValue
            || updateError.code == SUError.installationCanceledError.rawValue {
            onIssueChange?(nil)
            return
        }
        onIssueChange?("Update failed: \(error.localizedDescription)")
    }
}

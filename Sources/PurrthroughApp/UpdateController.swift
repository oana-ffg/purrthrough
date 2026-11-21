import AppKit
import Sparkle

/// Signed Sparkle updates from GitHub Releases, with a single user-facing switch.
///
/// With automatic updates on, Sparkle checks daily, downloads in the background
/// and installs right away. Purrthrough relaunches by itself and resumes playing
/// within a couple of seconds, so there is no reason to hold an update until quit.
@MainActor
final class UpdateController: NSObject, @preconcurrency SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        do { try controller.updater.start() }
        catch { onError?("Automatic updates could not start: \(error.localizedDescription)") }
    }

    var updatesAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle requires the delegate to return before the handler runs.
        Task { @MainActor in installHandler() }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let updateError = error as NSError
        // Sparkle reports these normal outcomes through the same abort callback.
        if updateError.domain == SUSparkleErrorDomain,
           updateError.code == SUError.noUpdateError.rawValue
            || updateError.code == SUError.installationCanceledError.rawValue {
            return
        }
        onError?("Update failed: \(error.localizedDescription)")
    }
}

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let playthrough = PlaythroughController()
    private let updater = UpdateController()
    private var statusItem: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(playthrough: playthrough, updater: updater)
        playthrough.start()
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        playthrough.stop()
    }
}

import AppKit
import ServiceManagement

/// The menu-bar cat and its menu. The menu is rebuilt each time it opens so the
/// device list and toggles always reflect the current state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let playthrough: PlaythroughController
    private let updater: UpdateController
    private var updateIssue: String?

    init(playthrough: PlaythroughController, updater: UpdateController) {
        self.playthrough = playthrough
        self.updater = updater
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        playthrough.onStatusChange = { [weak self] in self?.refreshIcon() }
        updater.onError = { [weak self] message in
            self?.updateIssue = message
            self?.refreshIcon()
        }
        refreshIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText))
        if playthrough.status == .needsMicrophoneAccess {
            menu.addItem(action("Open Microphone Settings…", #selector(openMicrophoneSettings)))
        }
        menu.addItem(toggle("Play Through", on: playthrough.isEnabled, #selector(togglePlaythrough)))
        let volume = NSMenuItem()
        volume.view = VolumeMenuView(volume: playthrough.volume, maximum: PlaybackGain.maximum) { [weak self] value in
            self?.playthrough.volume = value
        }
        menu.addItem(volume)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Input"))
        do {
            let inputs = try playthrough.availableInputs()
            if inputs.isEmpty { menu.addItem(disabled("No input devices")) }
            for input in inputs {
                let title = input.isBluetooth ? "\(input.name) (Bluetooth: call quality)" : input.name
                let entry = toggle(title, on: input.uid == playthrough.selectedInputUID, #selector(chooseInput(_:)))
                entry.representedObject = input.uid
                menu.addItem(entry)
            }
        } catch {
            menu.addItem(disabled("Cannot list inputs: \(error.localizedDescription)"))
        }
        menu.addItem(.sectionHeader(title: "Output"))
        menu.addItem(disabled("Follows the system output"))
        menu.addItem(.separator())

        menu.addItem(toggle("Start at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(toggle("Update Automatically", on: updater.updatesAutomatically, #selector(toggleUpdates)))
        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        if let updateIssue { menu.addItem(disabled(updateIssue)) }
        menu.addItem(.separator())
        menu.addItem(action("About Purrthrough", #selector(showAbout)))
        menu.addItem(action("Quit Purrthrough", #selector(quit), key: "q"))
    }

    private var statusText: String {
        switch playthrough.status {
        case .off: "Off"
        case .needsMicrophoneAccess: "Needs permission to hear the input"
        case .noInputChosen: "Choose an input below"
        case .waitingForInput(let name): "Waiting for \(name)"
        case .playing(let input, let output): "\(input) → \(output)"
        case .failed(let message): "Problem: \(message)"
        }
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let image: NSImage?
        switch playthrough.status {
        case .playing, .off, .waitingForInput, .noInputChosen:
            // The meowing cat; dimmed whenever it isn't passing sound through.
            image = NSImage(named: "MenuBarIcon")
            image?.accessibilityDescription = "Purrthrough"
            button.appearsDisabled = !isPlaying
        case .needsMicrophoneAccess, .failed:
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Purrthrough needs attention")
            button.appearsDisabled = false
        }
        image?.isTemplate = true
        button.image = image
        button.toolTip = updateIssue.map { "\(statusText)\n\($0)" } ?? statusText
    }

    private var isPlaying: Bool {
        if case .playing = playthrough.status { return true }
        return false
    }

    @objc private func togglePlaythrough() {
        playthrough.isEnabled.toggle()
    }

    @objc private func chooseInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        do {
            guard let input = try playthrough.availableInputs().first(where: { $0.uid == uid }) else { return }
            playthrough.selectInput(input)
        } catch {
            present(error, doing: "choose that input")
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(error, doing: "change Start at Login")
        }
    }

    @objc private func toggleUpdates() {
        updater.updatesAutomatically.toggle()
    }

    @objc private func checkForUpdates() {
        updateIssue = nil
        refreshIcon()
        updater.checkForUpdates()
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func present(_ error: Error, doing task: String) {
        let alert = NSAlert(error: error)
        alert.messageText = "Purrthrough could not \(task)."
        NSApp.activate()
        alert.runModal()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let entry = action(title, selector)
        entry.state = on ? .on : .off
        return entry
    }
}

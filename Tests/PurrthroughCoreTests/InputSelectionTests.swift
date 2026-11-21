import Testing
@testable import PurrthroughCore

struct InputSelectionTests {
    let lineIn = InputDeviceInfo(uid: "usb-line", name: "CUBILUX HLMS-C4 Line IN", isBluetooth: false)
    let usbMic = InputDeviceInfo(uid: "usb-mic", name: "USB PnP Sound Device", isBluetooth: false)
    let headset = InputDeviceInfo(uid: "bt", name: "Bluetooth Headline Set", isBluetooth: true)

    @Test func savedChoiceWins() {
        #expect(InputSelection.choose(savedUID: "usb-mic", available: [lineIn, usbMic]) == usbMic)
    }

    @Test func missingSavedChoiceWaitsInsteadOfFallingBack() {
        #expect(InputSelection.choose(savedUID: "usb-mic", available: [lineIn]) == nil)
    }

    @Test func autoPicksLineInputButNeverBluetooth() {
        #expect(InputSelection.choose(savedUID: nil, available: [headset, usbMic, lineIn]) == lineIn)
        #expect(InputSelection.choose(savedUID: nil, available: [headset, usbMic]) == nil)
    }
}

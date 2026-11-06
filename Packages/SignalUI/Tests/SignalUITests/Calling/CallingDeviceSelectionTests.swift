// CallingDeviceSelection stories (ts/components/CallingDeviceSelection.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingDeviceSelectionTests {
    static func view(_ story: String) -> CallingDeviceSelection {
        let empty = AudioDeviceList(devices: [])
        let emptyMic = AudioDevicePref.specificDevice(AudioDevice(name: "", uniqueId: ""))
        let def = AudioDevice(name: "Default", uniqueId: "Default")
        let airpods = AudioDevice(name: "Natalie's Airpods (Bluetooth)", uniqueId: "aa")
        let speakers = AudioDeviceList(devices: [def, airpods, AudioDevice(name: "UE Boom (Bluetooth)", uniqueId: "bb")], defaultDevice: def)
        switch story {
        case "some-devices":
            return CallingDeviceSelection(availableCameras: [], availableMicrophones: empty, availableSpeakers: speakers, selectedCamera: "",
                                          selectedMicrophone: emptyMic, selectedSpeaker: .specificDevice(def))
        case "default-devices":
            let s = AudioDeviceList(devices: [AudioDevice(name: "default (Headphones)", uniqueId: "Default")], isWindows: true,
                                    communicationsDevice: AudioDevice(name: "Comms", uniqueId: "comms"),
                                    consoleDevice: AudioDevice(name: "Console", uniqueId: "console"))
            let m = AudioDeviceList(devices: [AudioDevice(name: "DefAuLt (Microphone)", uniqueId: "Default")], isWindows: true,
                                    communicationsDevice: AudioDevice(name: "Comms Mic", uniqueId: "comms"),
                                    consoleDevice: AudioDevice(name: "Console Mic", uniqueId: "console"))
            return CallingDeviceSelection(availableCameras: [], availableMicrophones: m, availableSpeakers: s, selectedCamera: "",
                                          selectedMicrophone: .windowsCommunications, selectedSpeaker: .windowsConsole)
        case "all-devices":
            let cam = "dfbe6effe70b0611ba0fdc2a9ea3f39f6cb110e6687948f7e5f016c111b7329c"
            let mics = AudioDeviceList(devices: [def, airpods], defaultDevice: AudioDevice(name: "Monitor of UE Boom (Bluetooth)", uniqueId: "bb.monitor"))
            return CallingDeviceSelection(availableCameras: [CameraDevice(deviceId: cam, label: "FaceTime HD Camera (Built-in) (9fba:bced)"),
                                                             CameraDevice(deviceId: "e2db196a31d50ff9b135299dc0beea67f65b1a25a06d8a4ce76976751bb7a08d",
                                                                          label: "Logitech Webcam (4e72:9058)")],
                                          availableMicrophones: mics, availableSpeakers: speakers, selectedCamera: cam,
                                          selectedMicrophone: .nonWindowsDefault, selectedSpeaker: .nonWindowsDefault)
        default:
            return CallingDeviceSelection(availableCameras: [], availableMicrophones: empty, availableSpeakers: empty, selectedCamera: "",
                                          selectedMicrophone: emptyMic, selectedSpeaker: .nonWindowsDefault)
        }
    }

    @Test(arguments: ["default", "some-devices", "default-devices", "all-devices"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(SmallDialogsTests.modal(Self.view(name)), story: "components-callingdeviceselection--\(name)", theme: theme)
    }
}

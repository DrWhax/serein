// Port of ts/components/CallingDeviceSelectionItems.dom.tsx (and the device types of
// ts/types/Calling.std.ts): camera, microphone and speaker selects.

import SignalI18n
import SwiftUI

public struct CameraDevice: Sendable, Hashable {
    public var deviceId: String
    public var label: String
    public init(deviceId: String, label: String) {
        self.deviceId = deviceId
        self.label = label
    }
}

public struct AudioDevice: Sendable, Hashable {
    public var name: String
    public var uniqueId: String
    public init(name: String, uniqueId: String) {
        self.name = name
        self.uniqueId = uniqueId
    }
}

/// `AudioDeviceList`
public struct AudioDeviceList: Sendable {
    public var devices: [AudioDevice]
    public var isWindows = false
    public var defaultDevice: AudioDevice?
    public var communicationsDevice: AudioDevice?
    public var consoleDevice: AudioDevice?
    public init(devices: [AudioDevice], isWindows: Bool = false, defaultDevice: AudioDevice? = nil, communicationsDevice: AudioDevice? = nil,
                consoleDevice: AudioDevice? = nil) {
        self.devices = devices
        self.isWindows = isWindows
        self.defaultDevice = defaultDevice
        self.communicationsDevice = communicationsDevice
        self.consoleDevice = consoleDevice
    }
}

/// `AudioDevicePref`
public enum AudioDevicePref: Sendable, Hashable {
    case nonWindowsDefault, windowsConsole, windowsCommunications
    case specificDevice(AudioDevice)

    /// `audioDevicePrefToId`
    var id: String {
        switch self {
        case .nonWindowsDefault: "nonWindowsDefault"
        case .windowsConsole: "windowsConsole"
        case .windowsCommunications: "windowsCommunications"
        case .specificDevice(let d): d.uniqueId
        }
    }

    /// `audioDevicePrefStrToAudioDevicePref`
    static func from(_ id: String, in list: AudioDeviceList) -> AudioDevicePref? {
        switch id {
        case "nonWindowsDefault": .nonWindowsDefault
        case "windowsConsole": .windowsConsole
        case "windowsCommunications": .windowsCommunications
        default: list.devices.first { $0.uniqueId == id }.map { .specificDevice($0) }
        }
    }
}

public struct CallingDeviceSelectionItems: View {
    let forceStackedLayout: Bool
    let availableCameras: [CameraDevice]
    let availableMicrophones: AudioDeviceList
    let availableSpeakers: AudioDeviceList
    let selectedCamera: String?
    let selectedMicrophone: AudioDevicePref
    let selectedSpeaker: AudioDevicePref
    let onSelectedCameraChange: (String) -> Void
    let onSelectedMicrophoneChange: (AudioDevicePref) -> Void
    let onSelectedSpeakerChange: (AudioDevicePref) -> Void
    @Environment(\.i18n) var i18n

    public init(forceStackedLayout: Bool = false, availableCameras: [CameraDevice], availableMicrophones: AudioDeviceList, availableSpeakers: AudioDeviceList,
                selectedCamera: String?, selectedMicrophone: AudioDevicePref, selectedSpeaker: AudioDevicePref,
                onSelectedCameraChange: @escaping (String) -> Void = { _ in }, onSelectedMicrophoneChange: @escaping (AudioDevicePref) -> Void = { _ in },
                onSelectedSpeakerChange: @escaping (AudioDevicePref) -> Void = { _ in }) {
        self.forceStackedLayout = forceStackedLayout
        self.availableCameras = availableCameras
        self.availableMicrophones = availableMicrophones
        self.availableSpeakers = availableSpeakers
        self.selectedCamera = selectedCamera
        self.selectedMicrophone = selectedMicrophone
        self.selectedSpeaker = selectedSpeaker
        self.onSelectedCameraChange = onSelectedCameraChange
        self.onSelectedMicrophoneChange = onSelectedMicrophoneChange
        self.onSelectedSpeakerChange = onSelectedSpeakerChange
    }

    /// `renderAudioOptions`
    func audioOptions(_ list: AudioDeviceList) -> [AxoSelectItem.Option] {
        var options: [AxoSelectItem.Option] = []
        if list.isWindows {
            if let d = list.communicationsDevice {
                options.append(.init(value: "windowsCommunications", label: i18n("icu:callingDeviceSelection__select--default_communications",
                                                                                ["deviceName": .string(d.name)])))
            }
            if let d = list.consoleDevice {
                options.append(.init(value: "windowsConsole", label: i18n("icu:callingDeviceSelection__select--default_console", ["deviceName": .string(d.name)])))
            }
        } else if let d = list.defaultDevice {
            options.append(.init(value: "nonWindowsDefault", label: i18n("icu:callingDeviceSelection__select--default-nonwin", ["deviceName": .string(d.name)])))
        }
        return options + list.devices.map { .init(value: $0.uniqueId, label: $0.name) }
    }

    /// `getMatchingValue`
    static func matching(_ options: [AxoSelectItem.Option], _ value: String?) -> String? {
        options.contains { $0.value == value } ? value : nil
    }

    func select(_ key: String, options: [AxoSelectItem.Option], value: String?, onChange: @escaping (String) -> Void) -> some View {
        AxoSelectItem.Root(label: i18n(key), disabled: options.isEmpty,
                           placeholder: options.isEmpty ? i18n("icu:callingDeviceSelection__select--no-device") : nil,
                           value: Binding { Self.matching(options, value) } set: { if let v = $0 { onChange(v) } }, options: options,
                           forceStackedLayout: forceStackedLayout)
    }

    public var body: some View {
        let cameras = availableCameras.map { AxoSelectItem.Option(value: $0.deviceId, label: $0.label) }
        let mics = audioOptions(availableMicrophones), speakers = audioOptions(availableSpeakers)
        select("icu:callingDeviceSelection__label--video", options: cameras, value: selectedCamera, onChange: onSelectedCameraChange)
        select("icu:callingDeviceSelection__label--audio-input", options: mics, value: selectedMicrophone.id) {
            if let p = AudioDevicePref.from($0, in: availableMicrophones) { onSelectedMicrophoneChange(p) }
        }
        select("icu:callingDeviceSelection__label--audio-output", options: speakers, value: selectedSpeaker.id) {
            if let p = AudioDevicePref.from($0, in: availableSpeakers) { onSelectedSpeakerChange(p) }
        }
    }
}

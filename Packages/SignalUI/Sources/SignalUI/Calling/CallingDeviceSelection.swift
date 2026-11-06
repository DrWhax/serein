// Port of ts/components/CallingDeviceSelection.dom.tsx: the call's "Settings" dialog — the
// camera, microphone and speaker selects (CallingDeviceSelectionItems, stacked) in one list.

import SignalI18n
import SwiftUI

public struct CallingDeviceSelection: View {
    let availableCameras: [CameraDevice]
    let availableMicrophones: AudioDeviceList
    let availableSpeakers: AudioDeviceList
    let selectedCamera: String?
    let selectedMicrophone: AudioDevicePref
    let selectedSpeaker: AudioDevicePref
    let onClose: () -> Void
    let onSelectedCameraChange: (String) -> Void
    let onSelectedMicrophoneChange: (AudioDevicePref) -> Void
    let onSelectedSpeakerChange: (AudioDevicePref) -> Void
    @Environment(\.i18n) var i18n

    public init(availableCameras: [CameraDevice], availableMicrophones: AudioDeviceList, availableSpeakers: AudioDeviceList, selectedCamera: String?,
                selectedMicrophone: AudioDevicePref, selectedSpeaker: AudioDevicePref, onClose: @escaping () -> Void = {},
                onSelectedCameraChange: @escaping (String) -> Void = { _ in }, onSelectedMicrophoneChange: @escaping (AudioDevicePref) -> Void = { _ in },
                onSelectedSpeakerChange: @escaping (AudioDevicePref) -> Void = { _ in }) {
        self.availableCameras = availableCameras
        self.availableMicrophones = availableMicrophones
        self.availableSpeakers = availableSpeakers
        self.selectedCamera = selectedCamera
        self.selectedMicrophone = selectedMicrophone
        self.selectedSpeaker = selectedSpeaker
        self.onClose = onClose
        self.onSelectedCameraChange = onSelectedCameraChange
        self.onSelectedMicrophoneChange = onSelectedMicrophoneChange
        self.onSelectedSpeakerChange = onSelectedSpeakerChange
    }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:callingDeviceSelection__settings-v2"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(padding: .md) {
                AxoList.Group {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group {
                                CallingDeviceSelectionItems(forceStackedLayout: true, availableCameras: availableCameras,
                                                            availableMicrophones: availableMicrophones, availableSpeakers: availableSpeakers,
                                                            selectedCamera: selectedCamera, selectedMicrophone: selectedMicrophone,
                                                            selectedSpeaker: selectedSpeaker, onSelectedCameraChange: onSelectedCameraChange,
                                                            onSelectedMicrophoneChange: onSelectedMicrophoneChange,
                                                            onSelectedSpeakerChange: onSelectedSpeakerChange)
                            }
                        }
                    }
                }
            }
        }
    }
}

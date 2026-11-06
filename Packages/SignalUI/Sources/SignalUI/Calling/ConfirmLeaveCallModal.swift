// Port of ts/components/ConfirmLeaveCallModal.dom.tsx: starting a call (or joining a call
// link) from the Calls tab while already in one asks to leave the current call first.

import SignalI18n
import SwiftUI

public struct ConfirmLeaveCallModal: View {
    let onCancel: () -> Void
    let leaveCurrentCallAndStartCallingLobby: () -> Void
    @Environment(\.i18n) var i18n

    public init(onCancel: @escaping () -> Void, leaveCurrentCallAndStartCallingLobby: @escaping () -> Void) {
        self.onCancel = onCancel
        self.leaveCurrentCallAndStartCallingLobby = leaveCurrentCallAndStartCallingLobby
    }

    public var body: some View {
        AxoConfirmDialog.Root(title: i18n("icu:CallsList__LeaveCallDialogTitle"), description: i18n("icu:CallsList__LeaveCallDialogBody")) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel"), action: onCancel)
            AxoConfirmDialog.Action(i18n("icu:CallsList__LeaveCallDialogButton--leave"), variant: .strongPrimary,
                                    action: leaveCurrentCallAndStartCallingLobby)
        }
    }
}

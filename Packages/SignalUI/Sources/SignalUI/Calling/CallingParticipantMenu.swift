// Port of ts/components/CallingParticipantMenu.dom.tsx: the force-dark menu on a call
// participant — mute (disabled while they are already muted) / unmute, view profile, go to
// chat, and (admins of a call link) remove from call, confirmed with "Remove" or "Block".

import SignalI18n
import SwiftUI

/// The actions available on a participant; nil hides the item.
public struct CallingParticipantMenuActions {
    public var isMuteAudioDisabled = false
    public var onMuteAudio: (() -> Void)?
    public var onUnmuteAudio: (() -> Void)?
    public var onViewProfile: (() -> Void)?
    public var onGoToChat: (() -> Void)?
    public var onBlockFromCall: (() -> Void)?
    public var onRemoveFromCall: (() -> Void)?
    public init() {}
}

public struct CallingParticipantMenu<Trigger: View>: View {
    let renderer: AxoMenuBuilder.Renderer
    let participantTitle: String?
    let actions: CallingParticipantMenuActions
    let trigger: Trigger
    @Binding var isOpen: Bool
    @State var location: CGPoint?
    @State var removeDialog = false
    @Environment(\.i18n) var i18n

    public init(renderer: AxoMenuBuilder.Renderer = .dropdownMenu, participantTitle: String?, actions: CallingParticipantMenuActions,
                isOpen: Binding<Bool> = .constant(false), @ViewBuilder trigger: () -> Trigger) {
        self.renderer = renderer
        self.participantTitle = participantTitle
        self.actions = actions
        _isOpen = isOpen
        self.trigger = trigger()
    }

    public var body: some View {
        AxoThemeOverride(theme: .forceDark) {
            AxoMenuBuilder.Root(renderer: renderer, isOpen: $isOpen, location: $location) { trigger } items: {
                if let mute = actions.onMuteAudio {
                    AxoMenuBuilder.Item(i18n("icu:CallingParticipantMenu__MuteAudio"), symbol: "mic-slash", disabled: actions.isMuteAudioDisabled,
                                        action: mute)
                }
                if let unmute = actions.onUnmuteAudio {
                    AxoMenuBuilder.Item(i18n("icu:CallingParticipantMenu__UnmuteAudio"), symbol: "mic-slash", action: unmute)
                }
                if let profile = actions.onViewProfile {
                    AxoMenuBuilder.Item(i18n("icu:CallingParticipantMenu__ViewProfile"), symbol: "person-circle", action: profile)
                }
                if let chat = actions.onGoToChat {
                    AxoMenuBuilder.Item(i18n("icu:CallingParticipantMenu__GoToChat"), symbol: "arrow-square-up[end]", action: chat)
                }
                if actions.onBlockFromCall != nil && actions.onRemoveFromCall != nil {
                    AxoMenuBuilder.Item(i18n("icu:CallingParticipantMenu__RemoveFromCall"), symbol: "minus-circle") { removeDialog = true }
                }
            }
            .overlay {
                if removeDialog {
                    AxoBaseDialog.Host {
                        AxoConfirmDialog.Root(title: nil,
                                              description: i18n("icu:CallingAdhocCallInfo__RemoveClientDialogBody",
                                                                ["name": .string(participantTitle ?? "")])) {
                            AxoConfirmDialog.Cancel(i18n("icu:cancel")) { removeDialog = false }
                            AxoConfirmDialog.Action(i18n("icu:CallingAdhocCallInfo__RemoveClientDialogButton--block"), variant: .strongDestructive) {
                                removeDialog = false
                                actions.onBlockFromCall?()
                            }
                            AxoConfirmDialog.Action(i18n("icu:CallingAdhocCallInfo__RemoveClientDialogButton--remove"), variant: .strongDestructive) {
                                removeDialog = false
                                actions.onRemoveFromCall?()
                            }
                        }
                    }
                }
            }
        }
    }
}

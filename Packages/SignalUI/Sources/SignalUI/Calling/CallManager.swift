// Port of ts/components/CallManager.dom.tsx (+ CallNeedPermissionScreen.dom.tsx): which
// calling surface is up — the "needs permission" screen, PiP, the lobby or the call screen
// (each force-dark, with the settings dialog, the participants panel and the presenting
// source picker over it) for the active call, else the incoming call bar — plus the
// ringtone and the 60s outgoing group ring.

import SignalI18n
import SwiftUI

/// `ActiveCallManager`'s choice for the active call.
public enum CallManagerStage: Sendable, Hashable {
    case needPermission, pip, lobby, screen

    /// Direct: the lobby until there is a call state; "needs permission" once it ended with
    /// RemoteHangupNeedPermission. Group / call link: the lobby until joined. PiP wins over both.
    public static func direct(hasCallState: Bool, endedNeedingPermission: Bool, pip: Bool) -> CallManagerStage {
        if endedNeedingPermission { return .needPermission }
        if pip { return .pip }
        return hasCallState ? .screen : .lobby
    }

    public static func group(joinState: GroupCallJoinState, pip: Bool) -> CallManagerStage {
        if pip { return .pip }
        return joinState == .joined ? .screen : .lobby
    }
}

/// The active call's surfaces, built by the app from its calling state.
public struct CallManagerActiveCall {
    public var stage: CallManagerStage
    public var conversation: CallingConversation
    public var lobby: () -> AnyView
    public var screen: () -> AnyView
    public var pip: () -> AnyView
    /// Open over the lobby or the call (`settingsDialogOpen`).
    public var deviceSelection: AnyView?
    /// The participants list or, for call links, CallingAdhocCallInfo (`showParticipantsList`).
    public var participantsPanel: AnyView?
    /// `presentingSourcesAvailable` (call screen only).
    public var presentingSources: AnyView?
    /// Ringing out a group call: the ring is dropped after 60s.
    public var mightBeRingingOutgoingGroupCall: Bool
    public var closeNeedPermissionScreen: () -> Void

    public init(stage: CallManagerStage, conversation: CallingConversation, lobby: @escaping () -> AnyView, screen: @escaping () -> AnyView,
                pip: @escaping () -> AnyView, deviceSelection: AnyView? = nil, participantsPanel: AnyView? = nil, presentingSources: AnyView? = nil,
                mightBeRingingOutgoingGroupCall: Bool = false, closeNeedPermissionScreen: @escaping () -> Void = {}) {
        self.stage = stage
        self.conversation = conversation
        self.lobby = lobby
        self.screen = screen
        self.pip = pip
        self.deviceSelection = deviceSelection
        self.participantsPanel = participantsPanel
        self.presentingSources = presentingSources
        self.mightBeRingingOutgoingGroupCall = mightBeRingingOutgoingGroupCall
        self.closeNeedPermissionScreen = closeNeedPermissionScreen
    }
}

/// `ringingCall` when there is no active call.
public struct CallManagerRingingCall {
    public var conversation: CallingConversation
    public var mode: IncomingCallBar.Mode
    public init(conversation: CallingConversation, mode: IncomingCallBar.Mode) {
        self.conversation = conversation
        self.mode = mode
    }
}

public struct CallManager: View {
    let activeCall: CallManagerActiveCall?
    let ringingCall: CallManagerRingingCall?
    /// Whether a ringtone may play for the ringing conversation (notification profiles).
    let shouldRing: (String) -> Bool
    let acceptCall: (String, Bool) -> Void
    let declineCall: (String) -> Void
    let playRingtone: () -> Void
    let stopRingtone: () -> Void
    let setOutgoingRing: (Bool) -> Void
    let setIsCallActive: (Bool) -> Void

    public init(activeCall: CallManagerActiveCall?, ringingCall: CallManagerRingingCall?, shouldRing: @escaping (String) -> Bool = { _ in true },
                acceptCall: @escaping (String, Bool) -> Void = { _, _ in }, declineCall: @escaping (String) -> Void = { _ in },
                playRingtone: @escaping () -> Void = {}, stopRingtone: @escaping () -> Void = {}, setOutgoingRing: @escaping (Bool) -> Void = { _ in },
                setIsCallActive: @escaping (Bool) -> Void = { _ in }) {
        self.activeCall = activeCall
        self.ringingCall = ringingCall
        self.shouldRing = shouldRing
        self.acceptCall = acceptCall
        self.declineCall = declineCall
        self.playRingtone = playRingtone
        self.stopRingtone = stopRingtone
        self.setOutgoingRing = setOutgoingRing
        self.setIsCallActive = setIsCallActive
    }

    var ringingId: String? { ringingCall?.conversation.id }

    public var body: some View {
        content
            .onAppear {
                setIsCallActive(activeCall != nil)
                ring(ringingId)
            }
            .onChange(of: activeCall != nil) { _, active in setIsCallActive(active) }
            .onChange(of: ringingId) { _, id in ring(id) }
            .task(id: activeCall?.mightBeRingingOutgoingGroupCall ?? false) {
                guard activeCall?.mightBeRingingOutgoingGroupCall == true else { return }
                try? await Task.sleep(for: .seconds(60))     // GROUP_CALL_RING_DURATION
                if !Task.isCancelled { setOutgoingRing(false) }
            }
    }

    func ring(_ id: String?) {
        if let id, shouldRing(id) { playRingtone() } else { stopRingtone() }
    }

    @ViewBuilder var content: some View {
        if let call = activeCall {
            switch call.stage {
            case .needPermission:
                CallNeedPermissionScreen(conversation: call.conversation, close: call.closeNeedPermissionScreen)
            case .pip:
                call.pip()
            case .lobby:
                AxoThemeOverride(theme: .forceDark) {
                    ZStack {
                        call.lobby()
                        if let d = call.deviceSelection { AxoBaseDialog.Host { d } }
                        if let p = call.participantsPanel { p }
                    }
                }
            case .screen:
                AxoThemeOverride(theme: .forceDark) {
                    ZStack {
                        call.screen()
                        if let s = call.presentingSources { AxoBaseDialog.Host { s } }
                        if let d = call.deviceSelection { AxoBaseDialog.Host { d } }
                        if let p = call.participantsPanel { p }
                    }
                }
            }
        } else if let ringing = ringingCall {
            IncomingCallBar(conversation: ringing.conversation, mode: ringing.mode,
                            acceptCall: { acceptCall(ringing.conversation.id, $0) }, declineCall: { declineCall(ringing.conversation.id) })
        }
    }
}

/// `CallNeedPermissionScreen`: the other side has to accept our message request first — their
/// 80px avatar, the explanation, Close; it closes itself after 10s.
public struct CallNeedPermissionScreen: View {
    let conversation: CallingConversation
    let close: () -> Void
    @Environment(\.i18n) var i18n

    public init(conversation: CallingConversation, close: @escaping () -> Void) {
        self.conversation = conversation
        self.close = close
    }

    public var body: some View {
        let gray05 = AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray05)
        let title = conversation.title.isEmpty ? i18n("icu:unknownContact") : conversation.title
        VStack(spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: conversation.title, size: 80, conversationType: .direct, color: conversation.color,
                   image: conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: conversation.avatar != nil)
            I18n("icu:callNeedPermission", components: ["title": .string(title)], style: LegacyType.body1())
                .multilineTextAlignment(.center)
                .cssTextColor(gray05)
                .frame(maxWidth: 400)
                .padding(.vertical, 28).padding(.horizontal, 14)     // margin: 2em 1em
            Button(action: close) {
                CSSText(i18n("icu:close"), style: LegacyType.body1(weight: 600), wrap: .nowrap, color: gray05)
                    .padding(.vertical, 7).padding(.horizontal, 14)     // 0.5em 1em
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgba: LegacyColor.gray65)))
            }
            .buttonStyle(UndimmedButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(rgba: LegacyColor.gray95))
        .task {
            try? await Task.sleep(for: .seconds(10))     // AUTO_CLOSE_MS
            if !Task.isCancelled { close() }
        }
    }
}

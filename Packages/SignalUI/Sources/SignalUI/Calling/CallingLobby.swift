// Port of ts/components/CallingLobby.dom.tsx + CallingLobby.scss: the pre-call screen — the
// mirrored local preview (camera, or the blurred own avatar) 28px from the top, the header,
// CallingPreCallInfo, "Your camera is off", the call-link notice, and the CallControls bar
// with video / mic / ring toggles and the join button (⇧V / ⇧M toggle video / mic).

import SignalI18n
import SwiftUI

public struct CallingLobby: View {
    public enum Mode: Sendable, Hashable { case direct, group, adhoc }

    let callMode: Mode
    let conversation: CallingConversation
    let me: CallingConversation
    let groupMembers: [CallingConversation]
    let peekedParticipants: [PeekedParticipant]
    let hasLocalAudio: Bool
    let hasLocalVideo: Bool
    let hasCamera: Bool
    let isAdhocAdminApprovalRequired: Bool
    let isAdhocJoinRequestPending: Bool
    let isConversationTooBigToRing: Bool
    let isCallFull: Bool
    let isOnline: Bool
    let outgoingRing: Bool
    let isSharingPhoneNumberWithEverybody: Bool
    let localVideo: LocalVideoModel?
    let setLocalAudio: (Bool) -> Void
    let setLocalVideo: (Bool) -> Void
    let setOutgoingRing: (Bool) -> Void
    let onJoinCall: () -> Void
    let onCallCanceled: () -> Void
    let toggleParticipants: () -> Void
    let togglePip: () -> Void
    let toggleSettings: (Bool) -> Void
    @State var isCallConnecting: Bool
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(callMode: Mode, conversation: CallingConversation, me: CallingConversation, groupMembers: [CallingConversation] = [],
                peekedParticipants: [PeekedParticipant] = [], hasLocalAudio: Bool, hasLocalVideo: Bool, hasCamera: Bool = true,
                isAdhocAdminApprovalRequired: Bool = false, isAdhocJoinRequestPending: Bool = false, isConversationTooBigToRing: Bool = false,
                isCallFull: Bool = false, isOnline: Bool = true, outgoingRing: Bool, isSharingPhoneNumberWithEverybody: Bool = false,
                localVideo: LocalVideoModel? = nil, setLocalAudio: @escaping (Bool) -> Void = { _ in }, setLocalVideo: @escaping (Bool) -> Void = { _ in },
                setOutgoingRing: @escaping (Bool) -> Void = { _ in }, onJoinCall: @escaping () -> Void = {}, onCallCanceled: @escaping () -> Void = {},
                toggleParticipants: @escaping () -> Void = {}, togglePip: @escaping () -> Void = {}, toggleSettings: @escaping (Bool) -> Void = { _ in }) {
        self.callMode = callMode
        self.conversation = conversation
        self.me = me
        self.groupMembers = groupMembers
        self.peekedParticipants = peekedParticipants
        self.hasLocalAudio = hasLocalAudio
        self.hasLocalVideo = hasLocalVideo
        self.hasCamera = hasCamera
        self.isAdhocAdminApprovalRequired = isAdhocAdminApprovalRequired
        self.isAdhocJoinRequestPending = isAdhocJoinRequestPending
        self.isConversationTooBigToRing = isConversationTooBigToRing
        self.isCallFull = isCallFull
        self.isOnline = isOnline
        self.outgoingRing = outgoingRing
        self.isSharingPhoneNumberWithEverybody = isSharingPhoneNumberWithEverybody
        self.localVideo = localVideo
        self.setLocalAudio = setLocalAudio
        self.setLocalVideo = setLocalVideo
        self.setOutgoingRing = setOutgoingRing
        self.onJoinCall = onJoinCall
        self.onCallCanceled = onCallCanceled
        self.toggleParticipants = toggleParticipants
        self.togglePip = togglePip
        self.toggleSettings = toggleSettings
        _isCallConnecting = State(initialValue: isAdhocJoinRequestPending)
    }

    var isGroupOrAdhoc: Bool { callMode != .direct }
    var shouldShowLocalVideo: Bool { hasLocalVideo && hasCamera && localVideo != nil }
    var isRingButtonVisible: Bool { isGroupOrAdhoc && peekedParticipants.isEmpty && groupMembers.count > 1 }

    var ringMode: RingMode {
        isGroupOrAdhoc ? (outgoingRing && !isConversationTooBigToRing ? .willRing : .willNotRing) : .willRing
    }

    var videoButton: CallingButtonType { hasLocalVideo ? .videoOn : (hasCamera ? .videoOff : .videoDisabled) }
    var audioButton: CallingButtonType { hasLocalAudio ? .audioOn : .audioOff }
    var ringButton: CallingButtonType {
        guard isRingButtonVisible else { return .ringDisabled }
        return isConversationTooBigToRing ? .ringDisabled : outgoingRing ? .ringOn : .ringOff
    }

    var joinVariant: CallingLobbyJoinButtonVariant {
        if isCallFull { return .callIsFull }
        if isCallConnecting { return .loading }
        if isAdhocAdminApprovalRequired { return .askToJoin }
        if !peekedParticipants.isEmpty || callMode == .adhoc { return .join }
        return .start
    }

    var canJoin: Bool { !isCallFull && !isCallConnecting && isOnline }
    var canLeave: Bool { (isAdhocAdminApprovalRequired && isCallConnecting) || isAdhocJoinRequestPending }

    var status: AnyView? {
        let gray20 = AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20)
        let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18)
        if isGroupOrAdhoc {
            return AnyView(CallParticipantCount(isAdhoc: callMode == .adhoc, isAdhocJoinRequestPending: isAdhocJoinRequestPending,
                                                participantCount: peekedParticipants.count, toggleParticipants: toggleParticipants))
        }
        if hasLocalVideo { return AnyView(CSSText(i18n("icu:ContactListItem__menu__video-call"), style: style, color: gray20)) }
        if hasLocalAudio { return AnyView(CSSText(i18n("icu:CallControls__InfoDisplay--audio-call"), style: style, color: gray20)) }
        return nil
    }

    /// `.module-CallingLobby__local-preview`: top 28px, 100% − 140px tall, 4:3 (camera off) or
    /// the video's width; mirrored (`rotateY(180deg)`), 8px corners.
    func localPreview(_ size: CGSize) -> some View {
        let h = max(0, size.height - 140)
        return Group {
            if shouldShowLocalVideo, let localVideo {
                // <video> is as wide as its frames (0px before the first one).
                if staticRendering {
                    Color.clear.frame(width: 0, height: h)
                } else {
                    LocalVideoView(model: localVideo, fit: .contain).frame(width: h * 4 / 3, height: h).opacity(0.6)
                }
            } else {
                CallBackgroundBlur(avatar: me.avatar, dim: true)
                    .frame(width: h * 4 / 3, height: h)
                    .scaleEffect(x: -1, y: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    var cameraIsOff: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        return VStack(spacing: 12) {
            SignalIcon("v3/video/video-slash-light", size: 24, color: white, mask: true).frame(width: 24, height: 24)
            CSSText(i18n("icu:calling__your-video-is-off"), style: LegacyType.body2(), alignment: .center, color: white)
        }
        .callingTextShadow()
        .frame(maxHeight: .infinity)
        .opacity(shouldShowLocalVideo ? 0 : 1)
        .padding(.vertical, 15)
    }

    @ViewBuilder var callLinkNotice: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        if callMode == .adhoc {
            Group {
                if isAdhocJoinRequestPending {
                    HStack(spacing: 8) {
                        Spinner(svgSize: .small, size: 16)
                        CSSText(i18n("icu:CallingLobby__CallLinkNotice--join-request-pending"), style: LegacyType.body1(), wrap: .nowrap, color: white)
                    }
                    .fixedSize()
                } else {
                    CSSText(i18n(isSharingPhoneNumberWithEverybody ? "icu:CallingLobby__CallLinkNotice--phone-sharing" : "icu:CallingLobby__CallLinkNotice"),
                            style: LegacyType.caption(), alignment: .center, color: white)
                        .frame(width: 340 - 36)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray78)))
            .padding(.bottom, 32)
        }
    }

    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color(rgba: LegacyColor.gray90)
                    // `position: absolute`: the preview is centred and may be wider than the
                    // window (a wide camera at full height); it never widens the layout, so
                    // the header (settings, ✕) and the controls stay in the window.
                    .overlay(alignment: .top) { localPreview(g.size) }
                    .clipped()
                VStack(spacing: 0) {
                    Color.clear.frame(height: 64).padding(.top, 12)
                    CallingPreCallInfo(conversation: conversation, meId: me.id, meAci: me.aci, ringMode: ringMode, groupMembers: groupMembers,
                                       isCallFull: isCallFull, peekedParticipants: peekedParticipants)
                    cameraIsOff
                    callLinkNotice
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 122.67, height: 0)
                        CallControlsBar(title: conversation.title, status: status) {
                            CallingButton(videoButton, onClick: { setLocalVideo(!hasLocalVideo) })
                            CallingButton(audioButton, onClick: { setLocalAudio(!hasLocalAudio) })
                            CallingButton(ringButton, isVisible: isRingButtonVisible, onClick: { setOutgoingRing(!outgoingRing) })
                        } action: {
                            if canLeave {
                                LegacyButton(i18n("icu:CallControls__JoinLeaveButton--hangup-group"), variant: .destructive,
                                             overrides: .init(paddingBlock: 7, background: AxoColor(light: LegacyColor.accentRed, dark: LegacyColor.accentRed),
                                                              paddingInline: 16, radius: 40, fontSize: 12, lineHeight: 17), action: onCallCanceled)
                            } else {
                                CallingLobbyJoinButton(variant: joinVariant, disabled: !canJoin) {
                                    isCallConnecting = true
                                    onJoinCall()
                                }
                            }
                        }
                        Color.clear.frame(width: 122.67, height: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: g.size.width, height: g.size.height)
                CallingHeader(isGroupCall: isGroupOrAdhoc, participantCount: peekedParticipants.count,
                              onCancel: onCallCanceled, togglePip: isAdhocJoinRequestPending ? togglePip : nil, toggleSettings: toggleSettings)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 32)
                    .padding(.trailing, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .background {
            Group {
                Button("") { setLocalVideo(!hasLocalVideo) }.keyboardShortcut("v", modifiers: .shift)
                Button("") { setLocalAudio(!hasLocalAudio) }.keyboardShortcut("m", modifiers: .shift)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

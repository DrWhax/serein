// Port of ts/components/CallScreen.dom.tsx (+ the module-ongoing-call / CallingToast styles):
// the full-window call — header, the ringing / connecting info, the remote participant(s)
// (1:1: their video over their blurred avatar; group: GroupCallRemoteParticipants), the
// persistent toasts (reconnecting, alone, someone presenting), the speaking indicator, our
// self view (bottom right, 106.67×80 or expanded 312×234), and the CallControls footer with
// video / mic / raise hand / share screen / react and Leave. Controls fade after 5s idle.
// Shortcuts: ⌃⇧E hang up, ⇧V video, ⇧M mic, ⇧H raise hand, ⇧P expand the self view.

import SignalI18n
import SwiftUI

/// The 1:1 call's state (ringrtc CallState as Desktop maps it).
public enum DirectCallState: Sendable, Hashable { case prering, ringing, accepted, reconnecting, ended }
public enum GroupCallConnectionState: Int, Sendable, Hashable { case notConnected = 0, connecting, connected, reconnecting }
public enum GroupCallJoinState: Int, Sendable, Hashable { case notJoined = 0, joining, pending, joined }

public struct CallScreenModel {
    public enum Mode {
        case direct(state: DirectCallState, hasRemoteVideo: Bool, hasRemoteAudio: Bool, remoteAudioLevel: Double, joinedAt: Date?,
                    remoteVideo: (any CallVideoFrameSource)?)
        case group(isAdhoc: Bool, connectionState: GroupCallConnectionState, joinState: GroupCallJoinState, participants: [GroupCallRemoteParticipantInfo],
                   viewMode: CallViewMode, raisedHands: [UInt32], localDemuxId: UInt32?, outgoingRing: Bool, presenting: Set<UInt32>,
                   speakerTime: [UInt32: Double], audioLevels: [UInt32: Double], videoSource: (UInt32) -> (any CallVideoFrameSource)?)
    }

    public var mode: Mode
    public var conversation: CallingConversation
    public var me: CallingConversation
    public var groupMembers: [CallingConversation]
    public var hasLocalAudio: Bool
    public var hasLocalVideo: Bool
    public var localAudioLevel: Double
    public var isPresenting: Bool
    public var selfViewExpanded: Bool
    public var localVideo: LocalVideoModel?
    /// Call links we administer: the requests to join (CallingPendingParticipants).
    public var isCallLinkAdmin: Bool = false
    public var pendingParticipants: [CallingParticipant] = []
    /// Presenting needs the screen-recording permission (`showNeedsScreenRecordingPermissionsWarning`).
    public var showNeedsScreenRecordingPermissionsWarning: Bool = false

    public init(mode: Mode, conversation: CallingConversation, me: CallingConversation, groupMembers: [CallingConversation] = [], hasLocalAudio: Bool,
                hasLocalVideo: Bool, localAudioLevel: Double = 0, isPresenting: Bool = false, selfViewExpanded: Bool = false, localVideo: LocalVideoModel? = nil,
                isCallLinkAdmin: Bool = false, pendingParticipants: [CallingParticipant] = []) {
        self.isCallLinkAdmin = isCallLinkAdmin
        self.pendingParticipants = pendingParticipants
        self.mode = mode
        self.conversation = conversation
        self.me = me
        self.groupMembers = groupMembers
        self.hasLocalAudio = hasLocalAudio
        self.hasLocalVideo = hasLocalVideo
        self.localAudioLevel = localAudioLevel
        self.isPresenting = isPresenting
        self.selfViewExpanded = selfViewExpanded
        self.localVideo = localVideo
    }
}

public struct CallScreenActions {
    public var setLocalAudio: (Bool) -> Void = { _ in }
    public var setLocalVideo: (Bool) -> Void = { _ in }
    public var togglePresenting: () -> Void = {}
    public var toggleRaiseHand: (Bool) -> Void = { _ in }
    public var toggleReactionPicker: () -> Void = {}
    /// `sendGroupCallReaction`
    public var sendReaction: (String) -> Void = { _ in }
    public var hangUp: () -> Void = {}
    public var togglePip: () -> Void = {}
    public var toggleSettings: (Bool) -> Void = { _ in }
    public var toggleParticipants: () -> Void = {}
    public var toggleSelfViewExpanded: () -> Void = {}
    public var changeCallView: (CallViewMode) -> Void = { _ in }
    public var approveUser: (CallingParticipant) -> Void = { _ in }
    public var denyUser: (CallingParticipant) -> Void = { _ in }
    public var batchUserAction: (CallingPendingParticipants.BatchAction, [String]) -> Void = { _, _ in }
    public var showPendingParticipant: (CallingParticipant) -> Void = { _ in }
    public var toggleScreenRecordingPermissionsDialog: (Bool) -> Void = { _ in }
    public var openSystemPreferences: @MainActor () -> Void = { ScreenRecordingPermission.openSystemSettings() }
    public init() {}
}

/// `.CallingToast`: subtitle text in a gray-80 pill.
struct CallingToastView<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .fixedSize()
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(Capsule().fill(Color(rgba: LegacyColor.gray80)))
    }
}

public struct CallScreen: View {
    let model: CallScreenModel
    let actions: CallScreenActions
    let now: Date
    @State var showControls = true
    @State var idleTask: Task<Void, Never>?
    @State var controlsHover = false
    @State var selfViewHover = false
    @State var localHandRaised: Bool?
    @State var showRaisedHandsList = false
    @State var showReactionPicker = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    /// The button toasts (CallingButtonToastsContainer), fed by the app's call state.
    let buttonToasts: CallingButtonToasts?
    /// Reaction toasts and bursts (CallingReactionsToastsContainer), fed by the app.
    let reactions: CallReactionsModel?

    /// - Parameter initialLocalHandRaised: the raise-hand button's state at mount (it then
    ///   follows our own clicks, not the synced raised hands).
    public init(model: CallScreenModel, actions: CallScreenActions = CallScreenActions(), now: Date = Date(), buttonToasts: CallingButtonToasts? = nil,
                reactions: CallReactionsModel? = nil, initialLocalHandRaised: Bool? = nil) {
        self.reactions = reactions
        self.model = model
        self.actions = actions
        self.now = now
        self.buttonToasts = buttonToasts
        _localHandRaised = State(initialValue: initialLocalHandRaised)
    }

    // MARK: derived state (CallScreen's switch on callMode)

    var isGroupCall: Bool { if case .group = model.mode { true } else { false } }
    var participants: [GroupCallRemoteParticipantInfo] { if case .group(_, _, _, let p, _, _, _, _, _, _, _, _) = model.mode { p } else { [] } }

    var flags: (isRinging: Bool, hasCallStarted: Bool, isConnecting: Bool, isConnected: Bool, isReconnecting: Bool, participantCount: Int) {
        switch model.mode {
        case .direct(let state, _, _, _, _, _):
            return (state == .ringing, state != .prering && state != .ringing, state == .prering, state == .accepted, state == .reconnecting,
                    state == .accepted ? 2 : 0)
        case .group(_, let conn, let join, let ps, _, _, _, let ring, _, _, _, _):
            let onlyMe = model.groupMembers.count == 1 && model.groupMembers.first?.id == model.me.id
            return (ring && ps.isEmpty && !onlyMe, join != .notJoined, conn == .connecting, conn == .connected, conn == .reconnecting, ps.count + 1)
        }
    }

    var hasRemoteVideo: Bool {
        switch model.mode {
        case .direct(_, let v, _, _, _, _): v
        case .group(_, _, _, let ps, _, _, _, _, _, _, _, _): ps.contains { $0.hasRemoteVideo }
        }
    }

    var isLonelyInCall: Bool {
        switch model.mode {
        case .direct: false
        case .group(_, _, _, let ps, _, _, _, _, _, _, _, _): ps.isEmpty
        }
    }

    var raisedHands: [UInt32] { if case .group(_, _, _, _, _, let r, _, _, _, _, _, _) = model.mode { r } else { [] } }
    var localDemuxId: UInt32? { if case .group(_, _, _, _, _, _, let d, _, _, _, _, _) = model.mode { d } else { nil } }
    var syncedLocalHandRaised: Bool { localDemuxId.map { raisedHands.contains($0) } ?? false }
    var currentPresenter: GroupCallRemoteParticipantInfo? {
        if case .group(_, _, _, let ps, _, _, _, _, let presenting, _, _, _) = model.mode { return ps.first { presenting.contains($0.demuxId) } }
        return nil
    }

    var isAudioOnly: Bool { !model.hasLocalVideo && !hasRemoteVideo }
    var controlsFadedOut: Bool { !showControls && !showReactionPicker && !isAudioOnly && flags.isConnected }

    var videoButton: CallingButtonType { model.isPresenting ? .videoDisabled : (model.hasLocalVideo ? .videoOn : .videoOff) }
    var audioButton: CallingButtonType { model.hasLocalAudio ? .audioOn : .audioOff }
    var presentingButton: CallingButtonType { model.isPresenting ? .presentingOn : (currentPresenter != nil ? .presentingDisabled : .presentingOff) }

    /// `renderDuration`
    static func duration(_ seconds: Int) -> String {
        let s = seconds % 60, m = (seconds / 60) % 60, h = seconds / 3600
        let mm = m < 10 ? "0\(m)" : "\(m)", ss = s < 10 ? "0\(s)" : "\(s)"
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(mm):\(ss)"
    }

    var status: AnyView? {
        let gray20 = AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20)
        let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18)
        func text(_ key: String) -> AnyView { AnyView(CSSText(i18n(key), style: style, wrap: .nowrap, color: gray20)) }
        let f = flags
        if f.isConnecting { return text("icu:outgoingCallConnecting") }
        if f.isRinging { return text("icu:outgoingCallRinging") }
        if f.isReconnecting { return text("icu:callReconnecting") }
        if case .group(let adhoc, _, _, _, _, _, _, _, _, _, _, _) = model.mode {
            return AnyView(CallParticipantCount(isAdhoc: adhoc, participantCount: f.participantCount, toggleParticipants: actions.toggleParticipants))
        }
        if f.isConnected, case .direct(_, _, _, _, let joinedAt?, _) = model.mode {
            let secs = Int(now.timeIntervalSince(joinedAt))
            return secs > 0 ? AnyView(CSSText(Self.duration(secs), style: style, wrap: .nowrap, color: gray20)) : nil
        }
        if model.hasLocalVideo { return text("icu:ContactListItem__menu__video-call") }
        if model.hasLocalAudio { return text("icu:CallControls__InfoDisplay--audio-call") }
        return nil
    }

    // MARK: pieces

    @ViewBuilder var remoteParticipants: some View {
        switch model.mode {
        case .direct(_, let hasVideo, _, _, _, let source):
            if flags.hasCallStarted {
                ZStack {
                    CallBackgroundBlur(avatar: model.conversation.avatar, darken: true)
                    model.conversation.avatarView(size: 80, i18n: i18n)
                    DirectCallRemoteParticipant(conversation: model.conversation, hasRemoteVideo: hasVideo, isReconnecting: flags.isReconnecting,
                                                videoSource: source)
                }
            } else {
                CallBackgroundBlur(avatar: model.conversation.avatar, darken: true)
            }
        case .group(_, _, _, let ps, let viewMode, _, _, _, let presenting, let speakerTime, let levels, let source):
            GroupCallRemoteParticipants(participants: ps, callViewMode: viewMode, presenting: presenting, speakerTime: speakerTime, audioLevels: levels,
                                        isCallReconnecting: flags.isReconnecting, videoSource: source)
                .padding(.top, 24)
        }
    }

    var lonelyNode: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        return ZStack {
            if (model.hasLocalVideo || model.isPresenting), let localVideo = model.localVideo, !staticRendering {
                LocalVideoView(model: localVideo, fit: .contain).scaleEffect(x: model.isPresenting ? -1 : 1, y: 1)
            } else if !(model.hasLocalVideo || model.isPresenting) {
                CallBackgroundBlur(avatar: model.me.avatar)
                VStack(spacing: 12) {
                    Color.clear.frame(height: 120)
                    SignalIcon("v3/video/video-slash-light", size: 24, color: white, mask: true).frame(width: 24, height: 24)
                    CSSText(i18n("icu:calling__your-video-is-off"), style: LegacyType.body2(), alignment: .center, color: white)
                }
                .callingTextShadow()
            }
        }
    }

    var selfView: some View {
        let expanded = model.selfViewExpanded
        let h: CGFloat = expanded ? 234 : 80, w: CGFloat = expanded ? 312 : 106.67
        let sending = model.hasLocalVideo || model.isPresenting
        let myOrder = syncedLocalHandRaised ? localDemuxId.flatMap { raisedHands.firstIndex(of: $0) } : nil
        return ZStack(alignment: .topLeading) {
            if sending {
                Color(rgba: LegacyColor.gray75)
                if let localVideo = model.localVideo, !staticRendering { LocalVideoView(model: localVideo, fit: .cover) }
            } else {
                Color(rgba: LegacyColor.gray78)
                CallBackgroundBlur(avatar: model.me.avatar)
                model.me.avatarView(size: 40, i18n: i18n).frame(width: w, height: h)
                // CallingStatusIndicator--NoVideo
                AxoSymbol.Icon("videocamera-slash-fill", size: 16, label: nil).cssTextColor(AxoColor(light: LegacyColor.white, dark: LegacyColor.white))
                    .padding(6)
                    .background(Capsule().fill(Color(rgba: RGBA(LegacyColor.gray80.r, LegacyColor.gray80.g, LegacyColor.gray80.b, 0.7))))
                    .padding(8)
                    .opacity(selfViewHover ? 0 : 1)
            }
            CallingAudioIndicator(hasAudio: model.hasLocalAudio, audioLevel: model.localAudioLevel, shouldShowSpeaking: model.localAudioLevel > 0)
                .frame(width: w, height: h, alignment: .topTrailing)
                .padding(.trailing, 8).padding(.top, 8)
                .frame(width: w, height: h, alignment: .topLeading)
            CallingButton(expanded ? .minimize : .maximize, size: expanded ? .pipUnpin : .selfView, onClick: actions.toggleSelfViewExpanded)
                .padding(8)
                .opacity(selfViewHover ? 1 : 0)
            if let myOrder {
                CallingStatusIndicatorHandRaised(isOnlyHandRaised: raisedHands.count == 1, raisedHandOrder: myOrder)
                    .frame(width: w, height: h, alignment: .bottomLeading)
                    .padding(.leading, 8).padding(.bottom, 8)
                    .frame(width: w, height: h, alignment: .topLeading)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color.black).shadow(color: Color(.sRGB, white: 0, opacity: 0.4), radius: 7, x: 0, y: 4)
        }
        .onHover { selfViewHover = $0 }
        .onTapGesture { actions.toggleSelfViewExpanded() }
        .animation(.easeOut(duration: 0.3), value: expanded)
    }

    var persistentToasts: some View {
        let gray15 = AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15)
        let style = LegacyType.subtitle()
        return VStack(spacing: 8) {
            if flags.isReconnecting {
                CallingToastView {
                    HStack(spacing: 8) {
                        Spinner(svgSize: .small, size: 16)
                        CSSText(i18n("icu:callReconnecting"), style: style, wrap: .nowrap, color: gray15)
                    }
                }
            }
            if isLonelyInCall && !flags.isRinging {
                CallingToastView { CSSText(i18n("icu:calling__in-this-call--zero"), style: style, alignment: .center, color: gray15) }
            }
            if let p = currentPresenter {
                CallingToastView {
                    CSSText(i18n("icu:calling__presenting--person-ongoing", ["name": .string(p.conversation.title)]), style: style, alignment: .center,
                            color: gray15)
                }
            }
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    var footer: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 122.67, height: 0)
            CallControlsBar(title: model.conversation.title, status: status) {
                CallingButton(videoButton, onHover: { controlsHover = $0 }, onClick: { actions.setLocalVideo(!model.hasLocalVideo) })
                CallingButton(audioButton, onHover: { controlsHover = $0 }, onClick: { actions.setLocalAudio(!model.hasLocalAudio) })
                if isGroupCall {
                    let raised = localHandRaised ?? syncedLocalHandRaised
                    CallingButton(raised ? .raiseHandOn : .raiseHandOff, onHover: { controlsHover = $0 }, onClick: {
                        localHandRaised = !raised
                        actions.toggleRaiseHand(!raised)
                    })
                }
                CallingButton(presentingButton, onHover: { controlsHover = $0 }, onClick: actions.togglePresenting)
                if isGroupCall { CallingButton(showReactionPicker ? .reactOn : .reactOff, onHover: { controlsHover = $0 }, onClick: {
                    showReactionPicker.toggle()
                    actions.toggleReactionPicker()
                }) }
            } action: {
                LegacyButton(i18n(isGroupCall ? "icu:CallControls__JoinLeaveButton--hangup-group" : "icu:CallControls__JoinLeaveButton--hangup-1-1"),
                             variant: .destructive,
                             overrides: .init(paddingBlock: 7, background: AxoColor(light: LegacyColor.accentRed, dark: LegacyColor.accentRed), paddingInline: 16,
                                              radius: 40, fontSize: 12, lineHeight: 17), action: actions.hangUp)
                    .onHover { controlsHover = $0 }
            }
            .opacity(controlsFadedOut ? 0 : 1)
            Color.clear.frame(width: 122.67, height: 0)
        }
        .frame(maxWidth: .infinity)
    }

    func resetIdle() {
        showControls = true
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, !controlsHover { showControls = false }
        }
    }

    public var body: some View {
        let f = flags
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color(rgba: LegacyColor.gray90)
                if isLonelyInCall { lonelyNode.frame(width: g.size.width, height: g.size.height) }
                VStack(spacing: 0) {
                    if f.isConnecting || f.isRinging {
                        Color.clear.frame(height: 64).padding(.top, 12)
                        CallingPreCallInfo(conversation: model.conversation, meId: model.me.id, meAci: model.me.aci, ringMode: .isRinging,
                                           groupMembers: model.groupMembers, isConnecting: f.isConnecting)
                    }
                    if case .direct = model.mode, f.hasCallStarted {
                        Color.clear.frame(maxHeight: .infinity)
                    } else if case .group = model.mode {
                        remoteParticipants.frame(maxHeight: .infinity)
                        if model.isCallLinkAdmin && !model.pendingParticipants.isEmpty {
                            // margin-block: auto 36px, between the grid and the footer.
                            CallingPendingParticipants(participants: model.pendingParticipants, approveUser: actions.approveUser,
                                                       denyUser: actions.denyUser, batchUserAction: actions.batchUserAction,
                                                       showParticipant: actions.showPendingParticipant)
                                .padding(.bottom, 36)
                        }
                    } else {
                        Color.clear.frame(maxHeight: .infinity)
                    }
                    if !(isDirectStarted) { footer }
                }
                .frame(width: g.size.width, height: g.size.height)
                .background { if case .direct = model.mode { remoteParticipants.frame(width: g.size.width, height: g.size.height) } }
                if isDirectStarted { footer.frame(width: g.size.width, height: g.size.height, alignment: .bottom) }
                CallingHeader(callViewMode: viewMode, isGroupCall: isGroupCall, participantCount: f.participantCount, togglePip: actions.togglePip,
                              toggleSettings: actions.toggleSettings, changeCallView: actions.changeCallView)
                    .opacity(controlsFadedOut ? 0 : 1)
                    .frame(width: g.size.width - 24, alignment: .trailing)
                    .padding(.top, 32)
                persistentToasts.frame(width: g.size.width)
                if case .direct(_, _, let hasAudio, let level, _, _) = model.mode {
                    CallingAudioIndicator(hasAudio: hasAudio, audioLevel: level, shouldShowSpeaking: level > 0)
                        .frame(width: g.size.width - 16, height: g.size.height - (model.selfViewExpanded ? (controlsFadedOut ? 232 : 330) : 112), alignment: .bottomTrailing)
                }
                if showReactionPicker {
                    // .CallControls__ReactionPickerContainer: min(44%, 32vw) into the 640px
                    // controls, 70px above their bottom (16px above the window's).
                    ReactionPicker(onPick: { emoji in
                        showReactionPicker = false
                        actions.sendReaction(emoji)
                    }, onClose: { showReactionPicker = false })
                    .shadow(color: Color(.sRGB, white: 0, opacity: 0.2), radius: 1.5, x: 0, y: 4)
                    .padding(.leading, max(0, (g.size.width - 640) / 2) + min(640 * 0.44, g.size.width * 0.32))
                    .padding(.bottom, 16 + 70)
                    .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
                }
                if let reactions {
                    // .CallingReactionsToasts: 32px above the 80px controls.
                    CallingReactionsToastsRegion(model: reactions)
                        .frame(width: g.size.width, height: max(0, g.size.height - 112), alignment: .bottomLeading)
                }
                if let buttonToasts {
                    // .CallingButtonToasts__outer: 16px above the 80px controls, centred.
                    CallingToastsRegion(queue: buttonToasts.queue) { action in
                        switch action {
                        case "lowerHand":
                            actions.toggleRaiseHand(false)
                            buttonToasts.queue.hide("SUGGEST_LOWER_HAND_TOAST_KEY")
                        case "openQueue": showRaisedHandsList = true
                        default: break
                        }
                    }
                    .frame(width: g.size.width, height: max(0, g.size.height - 96 - 16), alignment: .bottom)
                }
                if !raisedHands.isEmpty || showRaisedHandsList {
                    raisedHandsOverlay.frame(width: g.size.width, height: g.size.height)
                }
                if !isLonelyInCall {
                    selfView
                        .frame(width: g.size.width - 16, height: g.size.height - (model.selfViewExpanded && !controlsFadedOut ? 112 : 16), alignment: .bottomTrailing)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .overlay {
            // A modal in the app's theme (the call itself is always dark).
            if model.showNeedsScreenRecordingPermissionsWarning {
                AxoBaseDialog.Host {
                    NeedsScreenRecordingPermissionsModal(openSystemPreferencesAction: actions.openSystemPreferences,
                                                         toggleScreenRecordingPermissionsDialog: actions.toggleScreenRecordingPermissionsDialog)
                }
            }
        }
        .onContinuousHover { phase in if case .active = phase { resetIdle() } }
        .background {
            Group {
                Button("") { actions.hangUp() }.keyboardShortcut("e", modifiers: [.control, .shift])
                Button("") { actions.setLocalVideo(!model.hasLocalVideo); resetIdle() }.keyboardShortcut("v", modifiers: .shift)
                Button("") { actions.setLocalAudio(!model.hasLocalAudio); resetIdle() }.keyboardShortcut("m", modifiers: .shift)
                Button("") { actions.toggleRaiseHand(!(localHandRaised ?? syncedLocalHandRaised)); resetIdle() }.keyboardShortcut("h", modifiers: .shift)
                Button("") { actions.toggleSelfViewExpanded() }.keyboardShortcut("p", modifiers: .shift)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// The conversations behind the raised hands, in raise order (`conversationsByDemuxId`).
    var raisedHandConversations: [CallingConversation] {
        raisedHands.compactMap { id in
            id == localDemuxId ? model.me : participants.first { $0.demuxId == id }?.conversation
        }
    }

    /// `CallingRaisedHandsListButton` (16px from the bottom-leading corner) and, opened from it,
    /// the raised-hands list.
    var raisedHandsOverlay: some View {
        ZStack {
            CallingRaisedHandsListButtonOverlay(CallingRaisedHandsListButton(syncedLocalHandRaised: syncedLocalHandRaised,
                                                                             raisedHandsCount: raisedHands.count) {
                showRaisedHandsList.toggle()
            })
            if showRaisedHandsList && !raisedHands.isEmpty {
                CallingRaisedHandsListOverlay(CallingRaisedHandsList(raisedHands: raisedHandConversations, ourAci: model.me.aci,
                                                                     localHandRaised: syncedLocalHandRaised,
                                                                     onClose: { showRaisedHandsList = false },
                                                                     onLowerMyHand: {
                                                                         actions.toggleRaiseHand(false)
                                                                         showRaisedHandsList = false
                                                                     }))
            }
        }
    }

    var isDirectStarted: Bool { if case .direct = model.mode { flags.hasCallStarted } else { false } }
    var viewMode: CallViewMode? { if case .group(_, _, _, _, let v, _, _, _, _, _, _, _) = model.mode { v } else { nil } }
}

/// `DirectCallRemoteParticipant`: the other side's video (contained, blurred 15px while
/// reconnecting), or with no video `__remote-video-disabled` — gray-95 behind their blurred
/// avatar and the 96px avatar.
public struct DirectCallRemoteParticipant: View {
    let conversation: CallingConversation
    let hasRemoteVideo: Bool
    let isReconnecting: Bool
    let videoSource: (any CallVideoFrameSource)?
    @Environment(\.i18n) var i18n

    public init(conversation: CallingConversation, hasRemoteVideo: Bool, isReconnecting: Bool, videoSource: (any CallVideoFrameSource)?) {
        self.conversation = conversation
        self.hasRemoteVideo = hasRemoteVideo
        self.isReconnecting = isReconnecting
        self.videoSource = videoSource
    }

    public var body: some View {
        if hasRemoteVideo {
            RemoteVideoStack(source: videoSource, fit: .contain).blur(radius: isReconnecting ? 15 : 0)
        } else {
            ZStack {
                Color(rgba: LegacyColor.gray95)
                CallBackgroundBlur(avatar: conversation.avatar)
                conversation.avatarView(size: 96, i18n: i18n)
            }
        }
    }
}

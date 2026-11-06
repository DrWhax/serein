// Port of ts/components/CallingPip.dom.tsx + CallingPipRemoteVideo.dom.tsx (+ the
// module-calling-pip styles): the floating call while the app is used — the remote video or
// speaker (else the blurred avatar), our camera in the corner (or full-size when alone), the
// raised-hand / join-request pills, and on hover the un-pip button and video / mic / hang-up
// controls. Dragging moves it; it snaps to the nearest side (CallingPipContainer).

import SignalI18n
import SwiftUI

public struct CallingPip: View {
    /// `PIP_WIDTH_NORMAL` / `PIP_WIDTH_LARGE`, `PIP_STARTING_HEIGHT_*`, `PIP_TOP_MARGIN`, `PIP_PADDING`
    public static let widthNormal: CGFloat = 160, widthLarge: CGFloat = 224
    public static let heightNormal: CGFloat = 286, heightLarge: CGFloat = 400
    public static let topMargin: CGFloat = 78, padding: CGFloat = 15

    public enum Remote {
        case direct(hasRemoteVideo: Bool, source: (any CallVideoFrameSource)?)
        /// The speaker (presenter first, else the latest speaker) once joined.
        case group(speaker: GroupCallRemoteParticipantInfo?, source: (any CallVideoFrameSource)?)
    }

    let conversation: CallingConversation
    let remote: Remote
    let hasLocalAudio: Bool
    let hasLocalVideo: Bool
    let isGroupCall: Bool
    let isLonelyInCall: Bool
    let isPresenting: Bool
    let raisedHandsCount: Int
    let callJoinRequests: Int
    let localVideo: LocalVideoModel?
    let width: CGFloat
    let height: CGFloat
    let forceControls: Bool
    let setLocalAudio: (Bool) -> Void
    let setLocalVideo: (Bool) -> Void
    let hangUp: () -> Void
    let togglePip: () -> Void
    @State var showControls = false
    @State var controlsHover = false
    @State var hideTask: Task<Void, Never>?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(conversation: CallingConversation, remote: Remote, hasLocalAudio: Bool, hasLocalVideo: Bool, isGroupCall: Bool = false,
                isLonelyInCall: Bool = false, isPresenting: Bool = false, raisedHandsCount: Int = 0, callJoinRequests: Int = 0,
                localVideo: LocalVideoModel? = nil, width: CGFloat = CallingPip.widthLarge, height: CGFloat = CallingPip.heightLarge,
                forceControls: Bool = false, setLocalAudio: @escaping (Bool) -> Void = { _ in }, setLocalVideo: @escaping (Bool) -> Void = { _ in },
                hangUp: @escaping () -> Void = {}, togglePip: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.remote = remote
        self.hasLocalAudio = hasLocalAudio
        self.hasLocalVideo = hasLocalVideo
        self.isGroupCall = isGroupCall
        self.isLonelyInCall = isLonelyInCall
        self.isPresenting = isPresenting
        self.raisedHandsCount = raisedHandsCount
        self.callJoinRequests = callJoinRequests
        self.localVideo = localVideo
        self.width = width
        self.height = height
        self.forceControls = forceControls
        self.setLocalAudio = setLocalAudio
        self.setLocalVideo = setLocalVideo
        self.hangUp = hangUp
        self.togglePip = togglePip
    }

    var controlsVisible: Bool { showControls || forceControls }
    var avatarSize: CGFloat { width > Self.widthNormal ? 96 : 64 }

    /// `BlurredBackground`: the (speaker's or conversation's) avatar, blurred behind itself.
    func blurred(darken: Bool) -> some View {
        var avatar = conversation.avatar
        if case .group(let s?, _) = remote, let a = s.conversation.avatar { avatar = a }
        return ZStack {
            CallBackgroundBlur(avatar: avatar, darken: darken)
            Avatar(strings: AvatarStrings(i18n: i18n), title: conversation.title, size: avatarSize, conversationType: conversation.conversationType,
                   color: conversation.color, image: avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: avatar != nil)
        }
    }

    @ViewBuilder var remoteVideo: some View {
        if isLonelyInCall {
            ZStack {
                blurred(darken: true)
                if let localVideo, hasLocalVideo, !staticRendering {
                    LocalVideoView(model: localVideo, fit: .contain).scaleEffect(x: isPresenting ? -1 : 1, y: 1)
                }
            }
        } else {
            switch remote {
            case .direct(let hasVideo, let source):
                ZStack {
                    blurred(darken: hasVideo)
                    if hasVideo, let source, !staticRendering { RemoteVideoView(source: source, fit: .contain) }
                }
            case .group(let speaker, let source):
                ZStack {
                    blurred(darken: speaker?.hasRemoteVideo ?? false)
                    if let speaker {
                        GroupCallRemoteParticipant(participant: speaker, isInPip: true, videoSource: staticRendering ? nil : source)
                            .frame(width: width, height: 0)
                    }
                }
            }
        }
    }

    func pill(_ icon: String, _ count: Int) -> some View {
        let gray05 = AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray05)
        return HStack(spacing: 4) {
            SignalIcon(icon, size: 16, color: gray05, mask: true).frame(width: 16, height: 16)
            CSSText("\(count)", type: .bodySmall, wrap: .nowrap, color: gray05)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(Color(rgba: LegacyColor.gray80)))
    }

    var hangupType: CallingButtonType { isGroupCall ? .hangupGroup : .hangupDirect }
    var videoType: CallingButtonType { hasLocalVideo ? .videoOn : .videoOff }
    var audioType: CallingButtonType { hasLocalAudio ? .audioOn : .audioOff }

    func reveal() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, !controlsHover { showControls = false }
        }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            remoteVideo.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 18))
            if !isLonelyInCall && hasLocalVideo {
                ZStack {
                    Color(rgba: LegacyColor.gray80)
                    if let localVideo, !staticRendering { LocalVideoView(model: localVideo, fit: .contain) }
                }
                .frame(width: width > Self.widthNormal ? 120 : 80, height: width > Self.widthNormal ? 90 : 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(8)
            }
            CallingButton(.fullScreenCall, size: .pipUnpin, onHover: { controlsHover = $0 }, onClick: togglePip)
                .opacity(controlsVisible ? 1 : 0)
                .frame(width: width - 16, alignment: .trailing)
                .padding(.top, 16)
            if raisedHandsCount > 0 || callJoinRequests > 0 {
                HStack(spacing: 0) {
                    if raisedHandsCount > 0 { pill("v3/raise_hand/raise_hand", raisedHandsCount) }
                    if callJoinRequests > 0 { pill("v3/person/person-plus-compact", callJoinRequests) }
                }
                .frame(height: height - (controlsVisible ? 66 : 8), alignment: .bottom)
                .padding(.leading, 8)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CallingButton(videoType, size: .pip, onHover: { controlsHover = $0 }, onClick: { setLocalVideo(!hasLocalVideo) })
                CallingButton(audioType, size: .pip, onHover: { controlsHover = $0 }, onClick: { setLocalAudio(!hasLocalAudio) }).frame(width: 62)
                CallingButton(hangupType, size: .pip, onHover: { controlsHover = $0 }, onClick: hangUp)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: width - 8, height: 56)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(rgba: LegacyColor.gray78)))
            .opacity(controlsVisible ? 1 : 0)
            .offset(x: 4, y: height - (controlsVisible ? 60 : -4))
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 18))     // overflow: hidden (not the shadow)
        .background {
            RoundedRectangle(cornerRadius: 18).fill(Color(rgba: LegacyColor.gray95))
                .shadow(color: Color(.sRGB, white: 0, opacity: 0.05), radius: 4)
                .shadow(color: Color(.sRGB, white: 0, opacity: 0.3), radius: 10, x: 0, y: 8)
        }
        .animation(.easeOut(duration: 0.5), value: controlsVisible)
        .onContinuousHover { phase in if case .active = phase { reveal() } }
        .environment(\.colorScheme, .dark)
    }
}

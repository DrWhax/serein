// Port of ts/components/GroupCallRemoteParticipant.dom.tsx (+ the
// module-ongoing-call__group-call-remote-participant styles) and
// CallingStatusIndicatorHandRaised.dom.tsx: one participant's tile — their video, or their
// blurred avatar / blocked / missing-media-keys notice; the audio indicator; the name (on
// hover) or raised-hand pill in the footer; the white ring while they speak.

import SignalI18n
import SwiftUI

/// `GroupCallRemoteParticipantType` (the fields the tile shows).
public struct GroupCallRemoteParticipantInfo: Sendable, Hashable, Identifiable {
    public var demuxId: UInt32
    public var conversation: CallingConversation
    public var hasRemoteAudio: Bool
    public var hasRemoteVideo: Bool
    public var isBlocked: Bool
    public var mediaKeysReceived: Bool
    public var sharingScreen: Bool
    public var raisedHandOrder: Int?
    public var isOnlyHandRaised: Bool
    public var videoAspectRatio: Double?
    /// When the participant was added (`addedTime`, ms).
    public var addedTime: Int64?
    public var titleNoDefault: String?
    public var id: UInt32 { demuxId }

    public init(demuxId: UInt32, conversation: CallingConversation, hasRemoteAudio: Bool = false, hasRemoteVideo: Bool = true, isBlocked: Bool = false,
                mediaKeysReceived: Bool = true, sharingScreen: Bool = false, raisedHandOrder: Int? = nil, isOnlyHandRaised: Bool = false,
                videoAspectRatio: Double? = 1.3, addedTime: Int64? = nil, titleNoDefault: String? = nil) {
        self.demuxId = demuxId
        self.conversation = conversation
        self.hasRemoteAudio = hasRemoteAudio
        self.hasRemoteVideo = hasRemoteVideo
        self.isBlocked = isBlocked
        self.mediaKeysReceived = mediaKeysReceived
        self.sharingScreen = sharingScreen
        self.raisedHandOrder = raisedHandOrder
        self.isOnlyHandRaised = isOnlyHandRaised
        self.videoAspectRatio = videoAspectRatio
        self.addedTime = addedTime
        self.titleNoDefault = titleNoDefault ?? conversation.title
    }
}

/// `CallingStatusIndicatorHandRaised`: a 28px pill, the queue position and the raised hand.
public struct CallingStatusIndicatorHandRaised: View {
    let isOnlyHandRaised: Bool
    let raisedHandOrder: Int
    let inGrid: Bool
    let inRaisedHandsList: Bool

    public init(isOnlyHandRaised: Bool, raisedHandOrder: Int, inGrid: Bool = false, inRaisedHandsList: Bool = false) {
        self.isOnlyHandRaised = isOnlyHandRaised
        self.raisedHandOrder = raisedHandOrder
        self.inGrid = inGrid
        self.inRaisedHandsList = inRaisedHandsList
    }

    /// `$color-next-raised-hand`
    static let nextRaisedHand = RGBA(108 / 255.0, 226 / 255.0, 124 / 255.0, 1)

    public var body: some View {
        let isNext = isOnlyHandRaised || raisedHandOrder == 0
        let ink = AxoColor(light: RGBA(0, 0, 0, inRaisedHandsList && !isNext ? 0.85 : 0.9), dark: RGBA(0, 0, 0, inRaisedHandsList && !isNext ? 0.85 : 0.9))
        let background = isNext ? Self.nextRaisedHand : (inRaisedHandsList ? LegacyColor.gray02 : LegacyColor.white)
        let inline: CGFloat = isOnlyHandRaised ? 6 : 8
        HStack(spacing: 0) {
            if !isOnlyHandRaised {
                CSSText("\(raisedHandOrder + 1)", style: LegacyType.body2(weight: 500), wrap: .nowrap, color: ink).padding(.trailing, inGrid ? 2 : 4)
            }
            AxoSymbol.Icon("raisehand", size: 16, label: nil).cssTextColor(ink).offset(x: -1, y: -1)
        }
        .padding(.leading, inline)
        .padding(.trailing, inGrid ? 6 : inline)
        .frame(minWidth: 28)
        .frame(height: 28)     // height: 28px with 6px padding: the 18px line overflows, centred
        .background(Capsule().fill(Color(rgba: background)))
    }
}

public struct GroupCallRemoteParticipant: View {
    let participant: GroupCallRemoteParticipantInfo
    let width: CGFloat?
    let height: CGFloat?
    let isInPip: Bool
    let inGrid: Bool
    let isInOverflow: Bool
    let audioLevel: Double
    let remoteParticipantsCount: Int
    let isActiveSpeakerInSpeakerView: Bool
    let isCallReconnecting: Bool
    let showMissingMediaKeys: Bool
    let videoSource: (any CallVideoFrameSource)?
    let onClickRaisedHand: (() -> Void)?
    @State var hovered = false
    @State var receivedVideo = false
    @State var isWide: Bool
    @State var showErrorDialog = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(participant: GroupCallRemoteParticipantInfo, width: CGFloat? = nil, height: CGFloat? = nil, isInPip: Bool = false, inGrid: Bool = false,
                isInOverflow: Bool = false, audioLevel: Double = 0, remoteParticipantsCount: Int = 1, isActiveSpeakerInSpeakerView: Bool = false,
                isCallReconnecting: Bool = false, showMissingMediaKeys: Bool? = nil, videoSource: (any CallVideoFrameSource)? = nil,
                onClickRaisedHand: (() -> Void)? = nil) {
        self.participant = participant
        self.width = width
        self.height = height
        self.isInPip = isInPip
        self.inGrid = inGrid
        self.isInOverflow = isInOverflow
        self.audioLevel = audioLevel
        self.remoteParticipantsCount = remoteParticipantsCount
        self.isActiveSpeakerInSpeakerView = isActiveSpeakerInSpeakerView
        self.isCallReconnecting = isCallReconnecting
        self.showMissingMediaKeys = showMissingMediaKeys ?? !participant.mediaKeysReceived
        self.videoSource = videoSource
        self.onClickRaisedHand = onClickRaisedHand
        _isWide = State(initialValue: (participant.videoAspectRatio ?? 1) >= 1)
    }

    var isSpeaking: Bool { !isInPip && audioLevel > 0 }
    var wantsToShowVideo: Bool { participant.hasRemoteVideo && !participant.isBlocked && videoSource != nil }
    var hasVideoToShow: Bool { wantsToShowVideo && (receivedVideo || staticRendering) }
    var avatarSize: CGFloat { isInPip ? 48 : (min(width ?? 0, height ?? 0) >= 180 ? 96 : 48) }
    /// `@container (min-width: 180px) or (min-height: 180px)` (grid tiles only).
    var isLarge: Bool { inGrid && ((width ?? 0) >= 180 || (height ?? 0) >= 180) }

    var errorMessage: String {
        if participant.isBlocked { return i18n("icu:calling__blocked-participant", ["name": .string(participant.conversation.title)]) }
        if let t = participant.titleNoDefault { return i18n("icu:calling__missing-media-keys", ["name": .string(t)]) }
        return i18n("icu:calling__missing-media-keys--unknown-contact")
    }

    @ViewBuilder var noVideo: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        if participant.isBlocked || showMissingMediaKeys {
            let icon = participant.isBlocked ? "v3/block/block" : "v3/error/error-circle"
            if isInOverflow {
                Button { showErrorDialog = true } label: { SignalIcon(icon, size: 20, color: white, mask: true).frame(width: 20, height: 20) }
                    .buttonStyle(UndimmedButtonStyle())
                    .accessibilityLabel(errorMessage)
            } else {
                VStack(spacing: 0) {
                    SignalIcon(icon, size: 20, color: white, mask: true).frame(width: 20, height: 20).padding(.bottom, 12)
                    if isLarge {
                        CSSText(errorMessage, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 16), alignment: .center,
                                color: white)
                            .padding(.horizontal, 8).padding(.bottom, 16)
                    }
                    Button { showErrorDialog = true } label: {
                        CSSText(i18n("icu:moreInfo"), style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 16), wrap: .truncate,
                                color: white)
                            .padding(.vertical, 3).padding(.horizontal, 10)
                            .background(Capsule().fill(Color(.sRGB, white: 0, opacity: 0.3)))
                    }
                    .buttonStyle(UndimmedButtonStyle())
                }
            }
        } else {
            Avatar(strings: AvatarStrings(i18n: i18n), title: participant.conversation.title, size: avatarSize, conversationType: .direct,
                   color: participant.conversation.color, image: participant.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) },
                   hasAvatar: participant.conversation.avatar != nil)
        }
    }

    var footer: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        let name = CSSText(participant.conversation.title, style: LegacyType.body2(weight: 500), wrap: .truncate,
                           color: participant.raisedHandOrder != nil ? AxoColor(light: RGBA(0, 0, 0, 1), dark: RGBA(0, 0, 0, 1)) : white)
        let raisedNameVisible = participant.raisedHandOrder != nil && (inGrid || hovered)
        let raised = participant.raisedHandOrder != nil
        let pad: (bottom: CGFloat, inline: CGFloat) =
            if isInOverflow { raised ? (6, 6) : (8, 10) }      // `__overflow …__footer`
            else if raised && inGrid { (8, 8) }
            else { (isLarge ? 14 : 10, isLarge ? 16 : 12) }
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if let order = participant.raisedHandOrder {
                    Button { onClickRaisedHand?() } label: {
                        HStack(spacing: 0) {
                            CallingStatusIndicatorHandRaised(isOnlyHandRaised: participant.isOnlyHandRaised, raisedHandOrder: order, inGrid: inGrid || hovered)
                                .padding(.vertical, inGrid ? 1 : 0).padding(.leading, inGrid ? 5 : 0)
                            if raisedNameVisible { name.padding(.trailing, 12) }
                        }
                        .background {
                            if raisedNameVisible { Capsule().fill(Color(rgba: CallingStatusIndicatorHandRaised.nextRaisedHand)) }
                        }
                    }
                    .buttonStyle(UndimmedButtonStyle())
                } else {
                    name.opacity(hovered ? 1 : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, pad.inline).padding(.trailing, pad.inline).padding(.bottom, pad.bottom)
        .frame(height: isInOverflow ? 40 : 60)
        .frame(maxWidth: .infinity)
        .background {
            if hovered && participant.raisedHandOrder == nil {
                LinearGradient(colors: [.clear, Color(.sRGB, white: 0, opacity: 0.6)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    public var body: some View {
        ZStack {
            // In the PiP the tile is only as tall as its video: without one it has no height and
            // (overflow: hidden) shows nothing.
            if !hasVideoToShow && !isInPip {
                // `.module-calling__background--no-avatar`: gray-78
                if participant.isBlocked || participant.conversation.avatar == nil { Color(rgba: LegacyColor.gray78) }
                CallBackgroundBlur(avatar: participant.isBlocked ? nil : participant.conversation.avatar)
                noVideo
            }
            if wantsToShowVideo {
                RemoteVideoStack(source: videoSource, fit: .cover, onSize: { w, h in
                    receivedVideo = true
                    isWide = w >= h
                })
                .background(Color(rgba: LegacyColor.gray75))
                .blur(radius: isCallReconnecting ? 15 : 0)
                .opacity(hasVideoToShow ? 1 : 0)
            }
            if !isInPip {
                VStack { Spacer(); footer }
                CallingAudioIndicator(hasAudio: participant.hasRemoteAudio, audioLevel: audioLevel, shouldShowSpeaking: isSpeaking)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
            if isSpeaking && !isActiveSpeakerInSpeakerView && remoteParticipantsCount > 1 {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white, lineWidth: 3)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
        .alert(isPresented: $showErrorDialog) {
            Alert(title: Text(participant.isBlocked ? i18n("icu:calling__block-info-title", ["name": .string(participant.conversation.title)]) : errorMessage),
                  message: Text(i18n(participant.isBlocked ? "icu:calling__block-info" : "icu:calling__missing-media-keys-info")))
        }
    }
}

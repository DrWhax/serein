// Port of ts/components/IncomingCallBar.dom.tsx + IncomingCallBar.scss: the bar shown over the
// app while a call rings (fixed, 22px from the top, max 600px, gray-75, 70px): the avatar,
// the caller / group and who rings, and decline / accept (as audio) / accept video buttons,
// with the ⌃⇧A / ⌃⇧V / ⌃⇧D shortcuts.

import SignalI18n
import SwiftUI

public struct IncomingCallBar: View {
    public enum Mode: Sendable, Hashable {
        case direct(isVideoCall: Bool)
        case group(ringer: CallingConversation, otherMembersRung: [CallingConversation])
    }

    let conversation: CallingConversation
    let mode: Mode
    let acceptCall: (_ asVideoCall: Bool) -> Void
    let declineCall: () -> Void
    @Environment(\.i18n) var i18n

    public init(conversation: CallingConversation, mode: Mode, acceptCall: @escaping (Bool) -> Void, declineCall: @escaping () -> Void) {
        self.conversation = conversation
        self.mode = mode
        self.acceptCall = acceptCall
        self.declineCall = declineCall
    }

    var isVideoCall: Bool {
        if case .direct(let v) = mode { return v }
        return true
    }

    /// `GroupCallMessage` (only the first two names are used).
    var message: String {
        switch mode {
        case .direct(let video): return i18n(video ? "icu:incomingVideoCall" : "icu:incomingAudioCall")
        case .group(let ringer, let others):
            let r = ringer.participantName
            let names = others.prefix(2).map(\.participantName)
            switch others.count {
            case 0: return i18n("icu:incomingGroupCall__ringing-you", ["ringer": .string(r)])
            case 1: return i18n("icu:incomingGroupCall__ringing-1-other", ["ringer": .string(r), "otherMember": .string(names[0])])
            case 2: return i18n("icu:incomingGroupCall__ringing-2-others", ["ringer": .string(r), "first": .string(names[0]), "second": .string(names[1])])
            case 3: return i18n("icu:incomingGroupCall__ringing-3-others", ["ringer": .string(r), "first": .string(names[0]), "second": .string(names[1])])
            default:
                return i18n("icu:incomingGroupCall__ringing-many", ["ringer": .string(r), "first": .string(names[0]), "second": .string(names[1]),
                                                                    "remaining": .number(Double(others.count - 2))])
            }
        }
    }

    func callButton(_ icon: String, _ background: RGBA, _ tooltip: String, _ action: @escaping () -> Void) -> some View {
        Tooltip(tooltip, forceDark: true) {
            Button(action: action) {
                SignalIcon(icon, size: 24, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white), mask: true)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(rgba: background)))
            }
            .buttonStyle(IncomingCallButtonStyle())
            .accessibilityLabel(tooltip)
        }
        .frame(width: 40, height: 40)
        .padding(.horizontal, 12)
    }

    public var body: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                conversation.avatarView(size: 48, i18n: i18n)
                    .padding(.vertical, 8)
                    .padding(.leading, 16)
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(conversation.title, style: LegacyType.body1(weight: 600), wrap: .truncate, color: white)
                    CSSText(message, style: LegacyType.body2(), wrap: .clamp(2), color: white)
                }
                .padding(.leading, 12)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                callButton("v3/phone/phone-down-fill", LegacyColor.accentRed, i18n("icu:declineCall"), declineCall)
                    .keyboardShortcut("d", modifiers: [.control, .shift])
                if isVideoCall {
                    callButton("v3/video/video-slash-fill", LegacyColor.gray45, i18n("icu:acceptCallWithoutVideo")) { acceptCall(false) }
                        .keyboardShortcut("a", modifiers: [.control, .shift])
                    callButton("v3/video/video-fill", LegacyColor.accentGreen, i18n("icu:acceptCall")) { acceptCall(true) }
                        .keyboardShortcut("v", modifiers: [.control, .shift])
                } else {
                    callButton("v3/phone/phone-fill", LegacyColor.accentGreen, i18n("icu:acceptCall")) { acceptCall(false) }
                        .keyboardShortcut("a", modifiers: [.control, .shift])
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: 600)
        .frame(height: 70)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(rgba: LegacyColor.gray75)))
        .padding(.horizontal, 16)
    }
}

/// `:hover { box-shadow: 0 0 0 2px $color-ultramarine }`
struct IncomingCallButtonStyle: ButtonStyle {
    @State var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay { if hovered { Circle().stroke(Color(rgba: LegacyColor.ultramarine), lineWidth: 2).padding(-1) } }
            .onHover { hovered = $0 }
    }
}

// Port of ts/components/CallingPreCallInfo.dom.tsx + CallingPreCallInfo.scss: the lobby's
// centre — the 64px avatar, the title (title-2, one line) and who will be rung / notified
// or who is already in the call (body-1, two lines), white with the calling text shadow.

import SignalI18n
import SwiftUI

public enum RingMode: Sendable { case willNotRing, willRing, isRinging }

/// A participant seen by a peek (`titleNoDefault` nil: an unknown contact).
public struct PeekedParticipant: Sendable, Hashable {
    public var conversation: CallingConversation
    public var isKnown: Bool
    public init(_ conversation: CallingConversation, isKnown: Bool = true) {
        self.conversation = conversation
        self.isKnown = isKnown
    }
}

extension View {
    /// `@mixin calling-text-shadow`: text-shadow 0 0 4px black/40% (Gaussian σ = 2).
    func callingTextShadow() -> some View { shadow(color: Color(.sRGB, white: 0, opacity: 0.4), radius: 2) }
}

public struct CallingPreCallInfo: View {
    let conversation: CallingConversation
    let meId: String
    let meAci: String?
    let ringMode: RingMode
    let groupMembers: [CallingConversation]
    let isCallFull: Bool
    let isConnecting: Bool
    let peekedParticipants: [PeekedParticipant]
    @Environment(\.i18n) var i18n

    public init(conversation: CallingConversation, meId: String, meAci: String? = nil, ringMode: RingMode, groupMembers: [CallingConversation] = [],
                isCallFull: Bool = false, isConnecting: Bool = false, peekedParticipants: [PeekedParticipant] = []) {
        self.conversation = conversation
        self.meId = meId
        self.meAci = meAci
        self.ringMode = ringMode
        self.groupMembers = groupMembers
        self.isCallFull = isCallFull
        self.isConnecting = isConnecting
        self.peekedParticipants = peekedParticipants
    }

    public var subtitle: String { Self.subtitle(i18n: i18n, conversation: conversation, meId: meId, meAci: meAci, ringMode: ringMode,
                                                groupMembers: groupMembers, isCallFull: isCallFull, isConnecting: isConnecting,
                                                peekedParticipants: peekedParticipants) }

    public static func subtitle(i18n: Localizer, conversation: CallingConversation, meId: String, meAci: String?, ringMode: RingMode,
                                groupMembers: [CallingConversation], isCallFull: Bool, isConnecting: Bool, peekedParticipants: [PeekedParticipant]) -> String {
        if ringMode == .isRinging { return i18n(isConnecting ? "icu:outgoingCallConnecting" : "icu:outgoingCallRinging") }
        if isCallFull { return i18n("icu:calling__call-is-full") }
        if !peekedParticipants.isEmpty {
            if peekedParticipants.contains(where: { !$0.isKnown }) {
                return i18n("icu:calling__pre-call-info--only-unknown-contacts-in-call", ["count": .number(Double(peekedParticipants.count))])
            }
            var hasYou = false
            let names = peekedParticipants.map { p -> String in
                if let aci = p.conversation.aci, aci == meAci {
                    hasYou = true
                    return i18n("icu:you")
                }
                return p.conversation.participantName
            }
            switch names.count {
            case 1:
                return hasYou ? i18n("icu:calling__pre-call-info--another-device-in-call")
                    : i18n("icu:calling__pre-call-info--1-person-in-call", ["first": .string(names[0])])
            case 2: return i18n("icu:calling__pre-call-info--2-people-in-call", ["first": .string(names[0]), "second": .string(names[1])])
            case 3:
                return i18n("icu:calling__pre-call-info--3-people-in-call", ["first": .string(names[0]), "second": .string(names[1]), "third": .string(names[2])])
            default:
                return i18n("icu:calling__pre-call-info--many-people-in-call", ["first": .string(names[0]), "second": .string(names[1]),
                                                                                  "others": .number(Double(names.count - 2))])
            }
        }
        let members = conversation.conversationType == .direct ? [conversation.participantName]
            : groupMembers.filter { $0.id != meId }.map(\.participantName)
        let ring = ringMode == .willRing
        switch members.count {
        case 0: return i18n("icu:calling__pre-call-info--empty-group")
        case 1: return i18n(ring ? "icu:calling__pre-call-info--will-ring-1" : "icu:calling__pre-call-info--will-notify-1", ["person": .string(members[0])])
        case 2:
            return i18n(ring ? "icu:calling__pre-call-info--will-ring-2" : "icu:calling__pre-call-info--will-notify-2",
                        ["first": .string(members[0]), "second": .string(members[1])])
        case 3:
            return i18n(ring ? "icu:calling__pre-call-info--will-ring-3" : "icu:calling__pre-call-info--will-notify-3",
                        ["first": .string(members[0]), "second": .string(members[1]), "third": .string(members[2])])
        default:
            return i18n(ring ? "icu:calling__pre-call-info--will-ring-many" : "icu:calling__pre-call-info--will-notify-many",
                        ["first": .string(members[0]), "second": .string(members[1]), "others": .number(Double(members.count - 2))])
        }
    }

    public var body: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        VStack(spacing: 0) {
            conversation.avatarView(size: 64, i18n: i18n)
            CSSText(conversation.title, style: LegacyType.title2(), wrap: .clamp(1), alignment: .center, color: white)
                .callingTextShadow()
                .padding(.top, 16)
            CSSText(subtitle, style: LegacyType.body1(), wrap: .clamp(2), alignment: .center, color: white)
                .callingTextShadow()
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

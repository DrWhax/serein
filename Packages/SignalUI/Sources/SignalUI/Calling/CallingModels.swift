// The conversation and participant data the calling components show (the ConversationType
// fields upstream's calling props pick), and `getParticipantName`
// (ts/util/callingGetParticipantName.std.ts).

import SignalI18n
import SwiftUI

public struct CallingConversation: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var firstName: String?
    public var systemGivenName: String?
    public var systemNickname: String?
    public var nicknameGivenName: String?
    /// Avatar colour name (A100…A210).
    public var color: String
    public var avatar: RGBAImage?
    public var conversationType: AvatarConversationType
    public var isMe: Bool
    public var aci: String?
    public var acceptedMessageRequest: Bool

    public init(id: String, title: String, firstName: String? = nil, systemGivenName: String? = nil, systemNickname: String? = nil,
                nicknameGivenName: String? = nil, color: String = "A200", avatar: RGBAImage? = nil, conversationType: AvatarConversationType = .direct,
                isMe: Bool = false, aci: String? = nil, acceptedMessageRequest: Bool = true) {
        self.id = id
        self.title = title
        self.firstName = firstName
        self.systemGivenName = systemGivenName
        self.systemNickname = systemNickname
        self.nicknameGivenName = nicknameGivenName
        self.color = color
        self.avatar = avatar
        self.conversationType = conversationType
        self.isMe = isMe
        self.aci = aci
        self.acceptedMessageRequest = acceptedMessageRequest
    }

    /// `getParticipantName`
    public var participantName: String {
        for n in [nicknameGivenName, systemNickname, systemGivenName, firstName] { if let n, !n.isEmpty { return n } }
        return title
    }

    /// The conversation's avatar at `size` (image or initials).
    @MainActor
    public func avatarView(size: CGFloat, i18n: Localizer) -> Avatar {
        Avatar(strings: AvatarStrings(i18n: i18n), title: title, size: size, conversationType: conversationType, color: color,
               image: avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: avatar != nil, noteToSelf: false)
    }
}

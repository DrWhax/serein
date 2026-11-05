// ConversationHeader stories (ts/components/conversation/ConversationHeader.dom.stories.tsx).
// Titles and avatars are the stories' seeded getDefaultConversation values; each header is
// followed by the stories' renderPinnedMessagesBar / renderMiniPlayer placeholder text.

import CodecCore
import ImageGIF
import SwiftUI
import Testing
@testable import SignalUI

func fixtureGIF(_ name: String) -> RGBAImage? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: url), let image = try? GIFDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(image.stillImage)
}

@MainActor
@Suite struct ConversationHeaderTests {
    static let pinned = "If active, this is where the smart pinned messages bar would be"
    static let mini = "If active, this is where smart mini player would be"

    static func placeholder(_ text: String) -> some View {
        CSSText(text, style: CSSTextStyle(AxoType.bodyLarge)).frame(maxWidth: .infinity, alignment: .leading)
    }

    static func conv(_ title: String, name: String? = nil, image: String? = "kitten-2-64-64.jpg", group: Bool = false,
                     configure: (inout ConversationHeaderModel) -> Void = { _ in }) -> ConversationHeaderModel {
        var c = ConversationHeaderModel(id: title, type: group ? .group : .direct, title: title)
        c.name = name
        c.avatar = image.flatMap { $0.hasSuffix(".gif") ? fixtureGIF($0) : fixtureImage($0) }
        configure(&c)
        return c
    }

    static func header(_ c: ConversationHeaderModel, style: OutgoingCallButtonStyle = .both, smsOnly: Bool = false, activeCall: Bool = false,
                       warning: ContactSpoofingWarning? = nil, colliding: [ConversationAvatarData] = [], subheader: String = pinned) -> some View {
        ConversationHeader(conversation: c, hasActiveCall: activeCall, isSmsOnlyOrUnregistered: smsOnly, outgoingCallButtonStyle: style,
                           contactSpoofingWarning: warning, collidingAvatars: colliding) { placeholder(subheader) }
    }

    /// `<div><h3>{subtitle}</h3><ConversationHeader/></div>` per item.
    static func items(_ list: [(String, AnyView)]) -> some View {
        VStack(spacing: 0) {
            ForEach(list.indices, id: \.self) { i in
                CSSText(list[i].0, style: CSSTextStyle(AxoType.bodyLarge)).frame(maxWidth: .infinity, alignment: .leading)
                list[i].1
            }
        }
    }

    static let nyah = conv("Nyah Stroman")

    static var stories: [(String, AnyView)] {
        let fire = "Someone 🔥 Somewhere"
        let group = "Typescript support group"
        let fugit = conv("Fugit harum", image: "kitten-3-64-64.jpg", group: true)
        let alice = ConversationAvatarData(title: "Alice", image: fixtureImage("kitten-1-64-64.jpg"))
        let bob = ConversationAvatarData(title: "Bob", image: fixtureImage("kitten-2-64-64.jpg"))
        return [
            ("private-convo", AnyView(items([
                ("With name and profile, verified", AnyView(header(conv(fire, name: fire, image: "giphy-GVNvOUpeYmI7e.gif") { $0.isVerified = true }))),
                ("With name, not verified, no avatar", AnyView(header(conv(fire, name: fire, image: "kitten-1-64-64.jpg")))),
                ("With name, not verified, descenders", AnyView(header(conv("Joyrey 🔥 Leppey", name: "Joyrey 🔥 Leppey", image: "kitten-2-64-64.jpg")))),
                ("Profile, no name", AnyView(header(conv("🔥Flames🔥", image: "kitten-3-64-64.jpg")))),
                ("No name, no profile, no color", AnyView(header(conv("(202) 555-0011", image: "kitten-3-64-64.jpg")))),
                ("Disappearing messages set", AnyView(header(conv("(202) 555-0005", image: "kitten-3-64-64.jpg") { $0.expireTimer = 10 }))),
                ("Disappearing messages + verified", AnyView(header(conv("(202) 555-0005", image: "kitten-3-64-64.jpg") {
                    $0.expireTimer = 300
                    $0.isVerified = true
                }))),
                ("Muting Conversation", AnyView(header(conv("(202) 555-0006", image: "kitten-3-64-64.jpg") { $0.isMuted = true }))),
                ("SMS-only conversation", AnyView(header(conv("(202) 555-0006", image: "kitten-3-64-64.jpg"), smsOnly: true))),
            ]))),
            ("group", AnyView(items([
                ("Basic", AnyView(header(conv(group, name: group, image: "kitten-2-64-64.jpg") { $0.expireTimer = 10 }, style: .justVideo))),
                ("In a group you left - no disappearing messages", AnyView(header(conv(group, name: group, image: "kitten-1-64-64.jpg") {
                    $0.expireTimer = 10
                    $0.left = true
                }, style: .justVideo))),
                ("In a group with an active group call", AnyView(header(conv(group, name: group, image: "kitten-2-64-64.jpg") { $0.expireTimer = 10 },
                                                                        style: .join))),
                ("In a forever muted group", AnyView(header(conv("Way too many messages", name: "Way too many messages", image: "kitten-3-64-64.jpg") {
                    $0.expireTimer = 10
                    $0.isMuted = true
                }, style: .justVideo))),
            ]))),
            ("note-to-self", AnyView(items([("In chat with yourself", AnyView(header(conv("Me", image: nil) { $0.isMe = true }, style: .none)))]))),
            ("unaccepted", AnyView(items([("1:1 conversation", AnyView(header(conv("(202) 555-0007") { $0.acceptedMessageRequest = false }, style: .none)))]))),
            ("blocked", AnyView(items([
                ("Unaccepted & Blocked", AnyView(header(conv("(202) 555-0007") {
                    $0.acceptedMessageRequest = false
                    $0.isBlocked = true
                }, style: .none))),
                ("Accepted & Blocked", AnyView(header(conv("(202) 555-0007", image: "kitten-1-64-64.jpg") { $0.isBlocked = true }, style: .none))),
            ]))),
            ("direct-conversation-in-another-call", AnyView(header(nyah, activeCall: true))),
            ("direct-conversation-in-current-call", AnyView(header(nyah, style: .none, activeCall: true))),
            ("group-conversation-in-another-call", AnyView(header(fugit, style: .join, activeCall: true))),
            ("group-conversation-in-current-call", AnyView(header(fugit, style: .none, activeCall: true))),
            ("with-same-name-in-direct-conversation-warning", AnyView(header(nyah, warning: .directConversationWithSameTitle))),
            ("with-same-name-in-group-conversation-warning", AnyView(header(nyah, warning: .multipleGroupMembersWithSameTitle(sharedNames: 1,
                                                                                                                            conversationIds: ["a", "b"]),
                                                                             colliding: [alice, bob]))),
            ("with-same-names-in-group-conversation-warning", AnyView(header(nyah, warning: .multipleGroupMembersWithSameTitle(sharedNames: 2,
                                                                                                                             conversationIds: ["a", "b", "c", "d"])))),
            ("with-just-mini-player", AnyView(header(nyah, subheader: mini))),
            ("with-just-pinned-messages-bar", AnyView(header(nyah))),
            ("with-min-player-and-pinned-messages-bar", AnyView(header(nyah, subheader: mini))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<15)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationheader--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func lastAdminAlert(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { CannotLeaveGroupBecauseYouAreLastAdminAlert() } }
        try Snapshot.assertMatches(view, story: "components-conversation-conversationheader--last-admin-alert", theme: theme)
    }
}

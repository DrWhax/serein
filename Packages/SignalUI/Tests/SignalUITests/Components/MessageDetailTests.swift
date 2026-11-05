// ts/components/conversation/MessageDetail.dom.stories.tsx. The stories give every avatar a
// donor badge (getFakeBadge); badges are out of scope and not drawn (about 0.03% of the
// image each).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MessageDetailTests {
    static let now = TimelineMessageTests.now

    static func message(_ text: String, direction: MessageDirection = .incoming, group: Bool = false, avatar: String? = nil) -> MessageProps {
        var a = MessageProps.Author(id: "some-id", title: "Max")
        a.avatar = avatar.flatMap { fixtureImage($0) }
        var p = MessageProps(id: "my-message", direction: direction, author: a, text: text, timestamp: now)
        p.conversationType = group ? .group : .direct
        p.status = direction == .outgoing ? .sent : nil
        p.bubbleColor = .preset("crimson")
        return p
    }

    static func contact(_ title: String, _ avatar: String, _ status: SendStatus?, unidentified: Bool = false, keyError: Bool = false,
                        errors: [String] = []) -> MessageDetailContact {
        var c = MessageDetailContact(id: title, title: title, avatar: fixtureImage(avatar), status: status, statusTimestamp: status == nil ? nil : now)
        c.isUnidentifiedDelivery = unidentified
        c.isOutgoingKeyError = keyError
        c.errors = errors
        return c
    }

    static var stories: [(String, MessageDetail)] {
        let justMax = [contact("Just Max", "kitten-1-64-64.jpg", .delivered)]
        return [
            ("delivered-incoming", MessageDetail(message: message("A message from Max"), contacts: [contact("Max", "kitten-3-64-64.jpg", nil)],
                                                 sentAt: now, receivedAt: now)),
            ("delivered-outgoing", MessageDetail(message: message("A message to Max", direction: .outgoing), contacts: justMax, sentAt: now, receivedAt: now)),
            ("message-statuses", MessageDetail(message: message("A message to you all!", group: true, avatar: "kitten-2-64-64.jpg"), contacts: [
                contact("Max", "kitten-3-64-64.jpg", .sent, unidentified: true),
                contact("Sally", "kitten-3-64-64.jpg", .pending),
                contact("Terry", "kitten-2-64-64.jpg", .failed, unidentified: true),
                contact("Theo", "kitten-1-64-64.jpg", .delivered),
                contact("Nikki", "kitten-1-64-64.jpg", .read, unidentified: true),
            ], sentAt: now, receivedAt: now)),
            ("not-delivered", MessageDetail(message: message("A message to Max", direction: .outgoing), contacts: justMax, sentAt: now, receivedAt: nil)),
            ("no-contacts", MessageDetail(message: message("Is anybody there?", direction: .outgoing), contacts: [], sentAt: now, receivedAt: now)),
            ("all-errors", MessageDetail(message: message("A message from Max"), contacts: [
                contact("Max", "kitten-3-64-64.jpg", .failed, keyError: true),
                contact("Sally", "kitten-3-64-64.jpg", .failed, unidentified: true, errors: ["Stuff happened, in a bad way."]),
                contact("Terry", "kitten-2-64-64.jpg", .failed, unidentified: true, keyError: true),
            ], errors: ["Wow, that went bad."], sentAt: now, receivedAt: now)),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(TimelineMessageTests.stage(view.frame(maxWidth: .infinity)).environment(\.viewportWidth, 1200),
                                       story: "components-conversation-messagedetail--\(name)", theme: theme)
        }
    }
}

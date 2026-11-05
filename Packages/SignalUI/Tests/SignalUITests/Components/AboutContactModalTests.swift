// ts/components/conversation/AboutContactModal.dom.stories.tsx. Names and avatars are the
// seeded getDefaultConversation values the captures show.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AboutContactModalTests {
    static func contact(_ title: String, _ kitten: Int, configure: (inout AboutContactModal.Contact) -> Void = { _ in }) -> AboutContactModal.Contact {
        var c = AboutContactModal.Contact(id: title, title: title)
        c.avatar = fixtureImage("kitten-\(kitten)-64-64.jpg")
        configure(&c)
        return c
    }

    static var me: AboutContactModal.Contact { contact("Sienna Ernser", 1) { $0.isMe = true; $0.phoneNumber = "(111) 231-2132" } }

    static var stories: [(String, AboutContactModal)] {
        let bee = "🐝"
        return [
            ("defaults", AboutContactModal(contact: contact("Mattie Grady", 2))),
            ("me", AboutContactModal(contact: me)),
            ("me-with-username", AboutContactModal(contact: { var c = me; c.username = "myusername.04"; return c }())),
            ("me-with-label", AboutContactModal(contact: me, contactLabelEmoji: bee, contactLabelString: "Worker Bee", contactNameColor: "270")),
            ("long-label", AboutContactModal(contact: me, contactLabelEmoji: bee, contactLabelString: "𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫 𒐫", contactNameColor: "270")),
            ("long-label-all-emoji", AboutContactModal(contact: me, contactLabelEmoji: bee, contactLabelString: String(repeating: bee, count: 24),
                                                       contactNameColor: "270")),
            ("me-with-invalid-label-emoji", AboutContactModal(contact: me, contactLabelEmoji: "@", contactLabelString: "Worker Bee", contactNameColor: "270")),
            ("me-with-add-label", AboutContactModal(contact: me, canAddLabel: true)),
            ("me-with-add-label-edit-disabled", AboutContactModal(contact: me, canAddLabel: true, isEditMemberLabelEnabled: false)),
            ("verified", AboutContactModal(contact: contact("Bernadine Feil", 2) { $0.isVerified = true })),
            ("blocked", AboutContactModal(contact: contact("Regan Murazik", 1) { $0.isBlocked = true })),
            ("pending", AboutContactModal(contact: contact("Nyah Stroman", 2) { $0.acceptedMessageRequest = false })),
            ("no-messages", AboutContactModal(contact: contact("Arvid Smitham", 3) { $0.hasMessages = false })),
            ("with-about", AboutContactModal(contact: contact("Ray Barton", 3) { $0.about = "😀 About Me" })),
            ("signal-connection", AboutContactModal(contact: contact("Mattie Grady", 2), isSignalConnection: true)),
            ("system-contact", AboutContactModal(contact: contact("Lyla Ward", 1) {
                $0.isInSystemContacts = true; $0.systemGivenName = "Alice"; $0.phoneNumber = "+1 555 123-4567"
            }, isSignalConnection: true)),
            ("with-shared-groups", AboutContactModal(contact: contact("Carmine Hane", 2) { $0.about = "likes to chat" }, isSignalConnection: true,
                                                     sharedGroupNames: ["Axolotl lovers"])),
            ("direct-from-trusted-contact", AboutContactModal(contact: contact("Mattie Grady", 2), fromOrAddedByTrustedContact: true)),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        // Known items (plan.md): with-about / no-messages, the rows' 19.45px line boxes put
        // glyphs half a device pixel off Chromium's snapped baselines.
        let tolerance: [String: Double] = ["with-about": 0.015, "no-messages": 0.015]
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-conversation-aboutcontactmodal--\(name)", theme: theme, maxRatio: tolerance[name])
        }
    }

    @Test(arguments: ["light", "dark"])
    func profileNameWarning(theme: String) throws {
        let id = "components-conversation-profilenamewarningmodal--"
        for (name, type) in [("direct", ProfileNameWarningModal.ConversationType.direct), ("group", .group)] {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { ProfileNameWarningModal(conversationType: type) } },
                                       story: id + name, theme: theme)
        }
    }
}

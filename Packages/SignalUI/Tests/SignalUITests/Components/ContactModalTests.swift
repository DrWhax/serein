// ts/components/conversation/ContactModal.dom.stories.tsx. WithBadges is left out (donor
// badges are out of scope).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ContactModalTests {
    static var mattie: ContactModal.Contact {
        var c = ContactModal.Contact(id: "mattie", title: "Mattie Grady")
        c.avatar = fixtureImage("kitten-2-64-64.jpg")
        return c
    }
    static let group = ContactModal.Group(id: "group")

    static var stories: [(String, ContactModal)] {
        let muscle = "💪\u{1F3FC}"
        return [
            ("as-non-admin", ContactModal(contact: mattie, conversation: group)),
            ("with-label", ContactModal(contact: mattie, conversation: group, contactLabel: ContactLabel(labelString: "Strong", labelEmoji: muscle),
                                        contactNameColor: "180")),
            ("with-label-no-emoji", ContactModal(contact: mattie, conversation: group, contactLabel: ContactLabel(labelString: "Strong"), contactNameColor: "220")),
            ("with-label-invalid-emoji", ContactModal(contact: mattie, conversation: group, contactLabel: ContactLabel(labelString: "Strong", labelEmoji: "%"),
                                                      contactNameColor: "220")),
            ("long-label", ContactModal(contact: mattie, conversation: group,
                                        contactLabel: ContactLabel(labelString: String(repeating: "𒐫", count: 24), labelEmoji: "🐝"), contactNameColor: "270")),
            ("long-label-2", ContactModal(contact: mattie, conversation: group,
                                          contactLabel: ContactLabel(labelString: String(repeating: "﷽", count: 24), labelEmoji: "🐝"), contactNameColor: "270")),
            ("long-label-all-emoji", ContactModal(contact: mattie, conversation: group,
                                                  contactLabel: ContactLabel(labelString: String(repeating: "🐝", count: 24), labelEmoji: "🐝"), contactNameColor: "270")),
            ("as-admin", ContactModal(contact: mattie, conversation: group, areWeAdmin: true)),
            ("as-admin-viewing-admin", ContactModal(contact: mattie, conversation: group, areWeAdmin: true, isAdmin: true)),
            ("as-admin-viewing-admin-with-label", ContactModal(contact: mattie, conversation: { var g = group; g.attributesAdminOnly = true; return g }(),
                                                               areWeAdmin: true, isAdmin: true, contactLabel: ContactLabel(labelString: "Contact Label"))),
            ("as-admin-with-no-group-link", ContactModal(contact: mattie, conversation: group, areWeAdmin: true)),
            ("as-admin-viewing-non-member-of-group", ContactModal(contact: mattie, conversation: group, isMember: false)),
            ("without-phone-number", ContactModal(contact: mattie, conversation: group)),
            ("with-unread-stories", ContactModal(contact: mattie, conversation: group, hasStories: .unread)),
            ("in-system-contacts", ContactModal(contact: { var c = mattie; c.isInSystemContacts = true; return c }(), conversation: group)),
            ("in-another-call", ContactModal(contact: mattie, conversation: group, hasActiveCall: true)),
            ("in-call-together", ContactModal(contact: mattie, conversation: group, hasActiveCall: true, activeCallDemuxId: 123, isRemoteMuteVisible: true)),
            ("in-call-together-muted", ContactModal(contact: mattie, conversation: group, hasActiveCall: true, activeCallDemuxId: 123, isMuted: true,
                                                    isRemoteMuteVisible: true)),
            ("in-call-link-together-as-admin", ContactModal(contact: mattie, conversation: group, hasActiveCall: true, activeCallDemuxId: 123, isMuted: true,
                                                            isRemoteMuteVisible: true, isRemoveFromCallVisible: true)),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            // long-label-all-emoji: the emoji and layout match; below the label, edges at
            // quarter-point positions (the dialog is centred at y .25) round to the other pixel.
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-conversation-contactmodal--\(name)", theme: theme,
                                       maxRatio: name == "long-label-all-emoji" ? 0.03 : nil)
        }
    }
}

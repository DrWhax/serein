// ts/components/conversation/ContactDetail.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ContactDetailTests {
    static var full: ContactDetailFields {
        var f = ContactDetailFields()
        f.number = [.init(.home, "555-444-2323"), .init(.work, "555-444-3232"), .init(.mobile, "555-666-3232"),
                    .init(.custom, "333-666-3232", label: "special"), .init(.custom, "333-777-3232")]
        f.email = [.init(.home, "jerjor@fakemail.com"), .init(.work, "jerry.jordan@fakeco.com"), .init(.custom, "jj@privatething.net", label: "private"),
                   .init(.custom, "jordan@another.net")]
        f.address = [
            .init(type: .home, street: "555 Main St.", pobox: "2323-444", neighborhood: "Garden Place", city: "Boston", region: "MA", postcode: "33333", country: "US"),
            .init(type: .work, street: "333 Another St.", pobox: "2424-555", neighborhood: "Factory Place", city: "Boston", region: "MA", postcode: "33344",
                  country: "US"),
            .init(type: .custom, label: "vacation", street: "111 Dream St.", pobox: "111-333", neighborhood: "BeachVille", city: "Miami", region: "FL",
                  postcode: "44232", country: "US"),
            .init(type: .custom, street: "333 Fake St.", pobox: "123-444", neighborhood: "Downtown", city: "Boston", region: "MA", postcode: "33345", country: "US"),
        ]
        f.nicknameGiven = "NickGiven"
        f.nicknameFamily = "NickFamily"
        f.note = "This is an important and long note \n with line\n breaks."
        return f
    }

    static func gif(path: Bool = true, pending: Bool = false, size: Int = 10304, totalDownloaded: Int? = nil) -> MessageAttachment {
        var a = MessageAttachment(contentType: "image/gif", size: size)
        a.isDownloaded = path
        a.hasUrl = false
        a.pending = pending
        a.totalDownloaded = totalDownloaded
        return a
    }

    static func contact(given: String? = nil, family: String? = nil, org: String? = nil, avatar: MessageAttachment? = nil,
                        canMessage: Bool = true) -> SharedContact {
        var c = SharedContact(givenName: given, familyName: family, organization: org)
        c.avatar = avatar
        c.canMessage = canMessage
        return c
    }

    static var stories: [(String, ContactDetail)] {
        let jerry = contact(given: "Jerry", family: "Jordan", avatar: gif())
        var onlyEmail = ContactDetailFields()
        onlyEmail.email = [.init(.home, "jerjor@fakemail.com")]
        let empty = ContactDetailFields()
        return [
            ("fully-filled-out", ContactDetail(contact: jerry, fields: full)),
            ("fully-filled-out-not-downloaded", ContactDetail(contact: contact(given: "Jerry", family: "Jordan", avatar: gif(path: false)), fields: full)),
            ("fully-filled-out-downloading", ContactDetail(contact: contact(given: "Jerry", family: "Jordan",
                                                                            avatar: gif(path: false, pending: true, size: 10_000_000, totalDownloaded: 500_000)), fields: full)),
            ("fully-filled-out-transient-error", ContactDetail(contact: contact(given: "Jerry", family: "Jordan", avatar: gif(path: false)), fields: full)),
            ("fully-filled-out-permanent-error", ContactDetail(contact: contact(given: "Jerry", family: "Jordan", avatar: gif(path: false)), fields: full)),
            ("only-email", ContactDetail(contact: contact(), fields: onlyEmail)),
            ("given-name", ContactDetail(contact: contact(given: "Jerry"), fields: empty)),
            ("organization-only", ContactDetail(contact: contact(org: "Company 5"), fields: empty)),
            ("given-family-name", ContactDetail(contact: contact(given: "Jerry", family: "FamilyName"), fields: empty)),
            ("family-name", ContactDetail(contact: contact(family: "FamilyName"), fields: empty)),
            ("name-and-organization", ContactDetail(contact: contact(given: "Jerry", family: "FamilyName", org: "Organization"), fields: empty)),
            ("loading-avatar", ContactDetail(contact: contact(avatar: gif(pending: true)), fields: empty)),
            ("empty-with-account", ContactDetail(contact: contact(), fields: empty)),
            ("empty-without-account", ContactDetail(contact: contact(canMessage: false), fields: empty)),
            ("fully-filled-out-without-account", ContactDetail(contact: contact(given: "Jerry", family: "Jordan", avatar: gif(), canMessage: false), fields: full)),
            ("in-another-call", ContactDetail(contact: jerry, fields: full, hasActiveCall: true)),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, view) in Self.stories {
            try Snapshot.assertMatches(view, story: "components-conversation-contactdetail--\(name)", theme: theme)
        }
    }
}

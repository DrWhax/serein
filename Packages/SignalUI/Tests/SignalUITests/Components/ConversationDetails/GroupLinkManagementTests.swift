// ts/components/conversation/conversation-details/GroupLinkManagement.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct GroupLinkManagementTests {
    static func view(_ link: String? = nil, _ access: AccessControl? = nil, admin: Bool) -> some View {
        GroupLinkManagement(groupLink: link, addFromInviteLink: access, isAdmin: admin).frame(width: 1168)
    }

    static let stories: [(String, AnyView)] = [
        ("off-admin", AnyView(view(admin: true))),
        ("on-admin", AnyView(view("https://signal.group/1", .any, admin: true))),
        ("on-admin-admin-approval-needed", AnyView(view("https://signal.group/1", .administrator, admin: true))),
        ("on-non-admin", AnyView(view("https://signal.group/1", .any, admin: false))),
        ("off-non-admin-user-cannot-get-here", AnyView(view(admin: false))),
    ]

    @Test(arguments: ["light", "dark"], 0..<5)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-grouplinkmanagement--\(name)", theme: theme)
    }
}

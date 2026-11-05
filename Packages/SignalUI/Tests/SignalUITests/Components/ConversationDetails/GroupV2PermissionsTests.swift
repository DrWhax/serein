// ts/components/conversation/conversation-details/GroupV2Permissions.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct GroupV2PermissionsTests {
    static func permissions(announcementsOnly: Bool = false, ready: Bool = false, admin: Bool = false, nonAdminLabels: Bool = false) -> some View {
        GroupV2Permissions(announcementsOnly: announcementsOnly, announcementsOnlyReady: ready, areWeAdmin: admin, nonAdminsHaveLabels: nonAdminLabels)
            .frame(width: 1168)
    }

    static let stories: [(String, AnyView)] = [
        ("basic", AnyView(permissions(ready: true, admin: true))),
        ("basic-with-labels", AnyView(permissions(ready: true, admin: true, nonAdminLabels: true))),
        ("basic-with-non-admin-labels", AnyView(permissions(ready: true, admin: true, nonAdminLabels: true))),
        ("not-admin", AnyView(permissions(announcementsOnly: true))),
        ("admin-but-not-announcement-ready", AnyView(permissions(admin: true))),
        ("admin-not-announcement-ready-but-it-was-on", AnyView(permissions(announcementsOnly: true, admin: true))),
    ]

    @Test(arguments: ["light", "dark"], 0..<6)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-conversation-conversationdetails-groupv2permissions--\(name)", theme: theme)
    }
}

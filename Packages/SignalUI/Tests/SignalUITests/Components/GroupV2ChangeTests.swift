// GroupV2Change stories (ts/components/conversation/GroupV2Change.dom.stories.tsx). Their
// renderChange(...) calls and bare text are extracted to Fixtures/groupv2change-stories.json
// (constants as names, enums as numbers); contacts render as their constant names.

import SwiftUI
import Testing
@testable import SignalUI

struct GroupV2StoryItem: Decodable {
    struct Opts: Decodable {
        var groupMemberships: [GroupV2Change.Membership]?
        var groupBannedMemberships: [String]?
        var groupName: String?
        var areWeAdmin: Bool?
    }
    var text: String?
    var change: GroupV2ChangeModel?
    var opts: Opts?
}

@MainActor
@Suite struct GroupV2ChangeTests {
    static let names = ["OUR_ACI": "YOU", "OUR_PNI": "YOU", "CONTACT_A": "CONTACT_A", "CONTACT_A_PNI": "CONTACT_A", "CONTACT_B": "CONTACT_B",
                        "CONTACT_C": "CONTACT_C", "ADMIN_A": "ADMIN_A", "INVITEE_A": "INVITEE_A"]

    static func stories() throws -> [String: [GroupV2StoryItem]] {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try JSONDecoder().decode([String: [GroupV2StoryItem]].self, from: Data(contentsOf: dir.appendingPathComponent("groupv2change-stories.json")))
    }

    static let storyNames = ["multiple", "create", "title", "avatar", "access-attributes", "access-members", "access-invite-link", "member-add",
                             "member-add-from-invited", "member-add-from-link", "member-add-from-admin-approval", "member-remove", "member-privilege",
                             "pending-add-one", "pending-add-many", "pending-remove-one", "pending-remove-many", "admin-approval-add",
                             "admin-approval-remove", "admin-approval-bounce", "group-link-add", "group-link-reset", "group-link-remove",
                             "description-remove", "description-change", "announcement-group-change", "group-terminated", "summary"]

    static func view(_ items: [GroupV2StoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                if let text = item.text {
                    CSSText(text, style: CSSTextStyle(AxoType.bodyLarge)).frame(maxWidth: .infinity, alignment: .leading)
                } else if let change = item.change {
                    GroupV2Change(change: change, areWeAdmin: item.opts?.areWeAdmin ?? true, groupMemberships: item.opts?.groupMemberships,
                                  groupBannedMemberships: item.opts?.groupBannedMemberships, groupName: item.opts?.groupName,
                                  ourAci: "OUR_ACI", ourPni: "OUR_PNI", renderContact: { CSSTextRun(Self.names[$0] ?? "UNKNOWN") })
                }
            }
        }
    }

    @Test(arguments: ["light", "dark"], 0..<28)
    func story(theme: String, index: Int) throws {
        let name = Self.storyNames[index]
        let items = try #require(try Self.stories()[name])
        try Snapshot.assertMatches(Self.view(items), story: "components-conversation-groupv2change--\(name)", theme: theme)
    }
}

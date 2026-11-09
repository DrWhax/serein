// `canPinMessages`: direct chats always; groups only for current members, and only for admins
// when editing the group's info is restricted to admins.

import Foundation
import SignalCore
import Testing
@testable import SignalSafe

@Suite struct PinPermissionTests {
    func group(adminOnly: Bool, members: [(String, Int)]) throws -> GroupV2State {
        var g = GroupV2State()
        g.accessControl.attributes = adminOnly ? GroupAccess.administrator : GroupAccess.member
        let json = "[" + members.map { #"{"aci":"\#($0.0)","role":\#($0.1),"joinedAtVersion":0}"# }.joined(separator: ",") + "]"
        g.membersV2 = try JSONDecoder().decode([GroupMember].self, from: Data(json.utf8))
        return g
    }

    @Test func directChatsCanAlwaysPin() {
        #expect(SignalSession.canPinMessages(isGroup: false, group: nil, me: nil))
    }

    @Test func adminOnlyGroups() throws {
        let g = try group(adminOnly: true, members: [("admin", GroupRole.administrator), ("me", GroupRole.default)])
        #expect(!SignalSession.canPinMessages(isGroup: true, group: g, me: "me"))
        #expect(SignalSession.canPinMessages(isGroup: true, group: g, me: "admin"))
    }

    @Test func openGroupsAndNonMembers() throws {
        let g = try group(adminOnly: false, members: [("me", GroupRole.default)])
        #expect(SignalSession.canPinMessages(isGroup: true, group: g, me: "me"))
        #expect(!SignalSession.canPinMessages(isGroup: true, group: g, me: "left"))
        #expect(!SignalSession.canPinMessages(isGroup: true, group: nil, me: "me"))
    }
}

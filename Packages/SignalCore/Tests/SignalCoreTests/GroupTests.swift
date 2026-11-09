// Phase 4 step 1: Groups v2 against upstream's in-tree mock server.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite struct GroupModelTests {
    @Test func keysAndBlobs() throws {
        let keys = try GroupKeys.generate()
        #expect(keys.masterKey.count == 32 && keys.groupId.count == 32)
        #expect(try GroupKeys(masterKey: keys.masterKey) == keys)
        let cipher = try GroupCipher(keys)
        guard case .title(let t)? = try cipher.decryptAttribute(try cipher.encryptTitle("Book club")).content else { Issue.record("no title"); return }
        #expect(t == "Book club")
        let aci = UUID().uuidString.lowercased()
        #expect(try cipher.decryptAci(try cipher.encryptServiceId(aci)) == aci)
    }

    @Test func credentialRequestRange() {
        let day = GroupCredentials.day, now: Int64 = 1_800_000_000_000
        let today = now / day * day
        #expect(GroupCredentials.requestRange([], now: now)! == (today, today + 6 * day))
        let full = (0...6).map { GroupCredential(redemptionTime: today + Int64($0) * day, credential: "") }
        #expect(GroupCredentials.requestRange(full, now: now) == nil)
        #expect(GroupCredentials.requestRange(Array(full.prefix(3)), now: now)! == (today + 3 * day, today + 6 * day))
    }

    @Test func logRangeHeader() {
        #expect(GroupsAPI.parseRange("versions 3-10/40")! == (3, 10, 40))
        #expect(GroupsAPI.parseRange("bytes 3-10/40") == nil)
    }

    @Test func applyAndDiff() {
        let us = "11111111-1111-4111-8111-111111111111", alice = "22222222-2222-4222-8222-222222222222", bob = "33333333-3333-4333-8333-333333333333"
        var old = GroupV2State()
        old.revision = 3
        old.name = "Old"
        old.membersV2 = [GroupMember(aci: us, role: GroupRole.default, joinedAtVersion: 0), GroupMember(aci: alice, role: GroupRole.administrator, joinedAtVersion: 0)]
        var change = DecryptedGroupActions(version: 4)
        change.sourceServiceId = alice
        change.modifyTitle = .some("New")
        change.addMembers = [.init(aci: bob, role: GroupRole.default, profileKey: Data(repeating: 7, count: 32), joinFromInviteLink: false)]
        change.modifyMemberRoles = [(us, GroupRole.administrator)]
        change.modifyTimer = .some(3600)
        let r = GroupChangeApply.apply(change, to: old, ourAci: us)
        #expect(r.state.revision == 4 && r.state.name == "New" && r.state.isMember(bob) && r.state.isAdmin(us) && r.state.expireTimer == 3600)
        #expect(r.profileKeys[bob]?.count == 32)
        let messages = GroupDiff.extract(old: old, current: r.state, ourAci: us, ourPni: nil, source: alice)
        let types = messages.first?.details.map(\.type) ?? []
        #expect(types.contains("title") && types.contains("member-add") && types.contains("member-privilege"))
        #expect(messages.last?.timer == 3600)
    }
}

@Suite struct GroupActionTests {
    static let us = "11111111-1111-4111-8111-111111111111", alice = "22222222-2222-4222-8222-222222222222"
    static let bob = "33333333-3333-4333-8333-333333333333"

    static func setup() throws -> (GroupKeys, GroupV2State, GroupActionBuilder) {
        let keys = try GroupKeys.generate()
        var state = GroupV2State()
        state.revision = 7
        state.membersV2 = [GroupMember(aci: us, role: GroupRole.administrator, joinedAtVersion: 0), GroupMember(aci: alice, role: GroupRole.default, joinedAtVersion: 0)]
        state.pendingAdminApprovalV2 = [GroupPendingAdminApproval(aci: bob, timestamp: 1)]
        // Builders that need no credentials never touch the server params.
        return (keys, state, try GroupActionBuilder(keys: keys, state: state, ourAci: us, serverPublicParams: Data()))
    }

    /// Each builder's actions, decrypted and applied, give the intended state.
    func roundTrip(_ a: GroupActions, _ keys: GroupKeys, _ state: GroupV2State) throws -> GroupV2State {
        #expect(a.version == UInt32(state.revision + 1))
        var d = try GroupCipher(keys).decryptActions(a)
        d.sourceServiceId = Self.us
        return GroupChangeApply.apply(d, to: state, ourAci: Self.us).state
    }

    @Test func attributesAndAccess() throws {
        let (keys, state, b) = try Self.setup()
        var s = try roundTrip(try b.updateAttributes(title: "T", description: "D")!, keys, state)
        #expect(s.name == "T" && s.description == "D")
        s = try roundTrip(try b.disappearingMessagesTimer(600), keys, state)
        #expect(s.expireTimer == 600)
        s = try roundTrip(b.announcementsOnly(true), keys, state)
        #expect(s.announcementsOnly)
        s = try roundTrip(b.attributesAccess(GroupAccess.administrator), keys, state)
        #expect(s.accessControl.attributes == GroupAccess.administrator)
        s = try roundTrip(b.newGroupLink(password: Data(repeating: 1, count: 16), access: GroupAccess.administrator), keys, state)
        #expect(s.accessControl.addFromInviteLink == GroupAccess.administrator && s.groupInviteLinkPassword == Data(repeating: 1, count: 16).base64EncodedString())
        s = try roundTrip(b.terminate(), keys, state)
        #expect(s.terminated)
    }

    @Test func membersRequestsAndBans() throws {
        let (keys, state, b) = try Self.setup()
        var s = try roundTrip(try b.approveRequest(Self.bob), keys, state)
        #expect(s.isMember(Self.bob) && s.pendingAdminApprovalV2.isEmpty && s.member(Self.bob)?.approvedByAdmin == true)
        s = try roundTrip(try b.denyRequest(Self.bob), keys, state)
        #expect(!s.isPendingApproval(Self.bob) && s.isBanned(Self.bob))
        s = try roundTrip(try b.deleteMember(Self.alice), keys, state)
        #expect(!s.isMember(Self.alice) && s.isBanned(Self.alice))
        s = try roundTrip(try b.deleteMember(Self.us), keys, state)
        #expect(!s.isMember(Self.us) && !s.isBanned(Self.us))
        s = try roundTrip(try b.modifyRole(Self.alice, role: GroupRole.administrator), keys, state)
        #expect(s.isAdmin(Self.alice))
        s = try roundTrip(try b.modifyLabel(Self.alice, emoji: "🐝", label: "Keeper"), keys, state)
        #expect(s.member(Self.alice)?.labelEmoji == "🐝" && s.member(Self.alice)?.labelString == "Keeper")
        var banned = state
        banned.bannedMembersV2 = [GroupBannedMember(serviceId: Self.bob, timestamp: 2)]
        let b2 = try GroupActionBuilder(keys: keys, state: banned, ourAci: Self.us, serverPublicParams: Data())
        s = try roundTrip(try b2.unban(Self.bob), keys, banned)
        #expect(!s.isBanned(Self.bob))
        let invite = try b.addMembers([(Self.bob, nil)], now: 5)!
        s = try roundTrip(invite, keys, state)
        #expect(s.isPending(Self.bob) && s.pendingMembersV2.first?.addedByUserId == Self.us)
    }

    @Test func avatarBlobAndForm() throws {
        let keys = try GroupKeys.generate()
        var blob = Signalservice_GroupAttributeBlob()
        blob.avatar = Data([1, 2, 3])
        #expect(try GroupsService.decryptAvatar(try GroupCipher(keys).encryptAttribute(blob), keys: keys) == Data([1, 2, 3]))
        var form = Signalservice_AvatarUploadAttributes()
        form.key = "groups/abc"; form.credential = "c"; form.acl = "private"; form.algorithm = "AWS4"; form.date = "d"; form.policy = "p"; form.signature = "s"
        let (body, type) = GroupsAPI.multipart(form, file: Data("FILE".utf8), boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(type == "multipart/form-data; boundary=B")
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\ngroups/abc\r\n--B"))
        #expect(text.hasSuffix("Content-Type: application/octet-stream\r\n\r\nFILE\r\n--B--\r\n"))
    }

    @Test func groupLinks() throws {
        let link = GroupLink(masterKey: Data(repeating: 9, count: 32), inviteLinkPassword: Data(repeating: 4, count: 16))
        #expect(link.url.hasPrefix("https://signal.group/#"))
        #expect(try GroupLink(url: link.url) == link)
        #expect(try GroupLink(url: link.url.replacingOccurrences(of: "https://signal.group/", with: "sgnl://joingroup/")) == link)
        #expect(throws: GroupLinkError.self) { try GroupLink(url: "https://evil.example/#" + link.url.split(separator: "#")[1]) }
        #expect(throws: GroupLinkError.self) { try GroupLink(code: "AAAA") }
    }
}

@Suite(.serialized) struct GroupFlowTests {
    static func groupState(_ c: LinkedClient, _ masterKey: Data) async throws -> GroupV2State? {
        try await c.database.pool.read { db in try GroupStore.find(db, groupId: GroupKeys(masterKey: masterKey).groupId)?.state }
    }

    /// alice creates a group with us and writes to it: the message lands in the group and the
    /// first fetch (credentials, presentation, joined_at_version, logs) stores the state.
    @Test func receivesAGroupAndItsChanges() async throws {
        try await LinkedClient.with { c in
            let g = try await c.server.json("createGroup", ["title": "Mock club"])
            let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
            let ts = TestClock.next()
            _ = try await c.server.json("sendGroupText", ["groupId": groupId, "text": "hi group", "timestamp": ts])
            _ = try await c.log.waitFor("group update") { if case .other("groupUpdated", _) = $0 { return true } else { return false } }
            let state = try #require(try await Self.groupState(c, masterKey))
            #expect(state.name == "Mock club" && state.membersV2.count == 2 && state.isMember(c.phoneAci) && state.isMember(c.aliceAci))
            let groupMessage = try await c.messageJSON(sentAt: ts)
            #expect(groupMessage["body"] as? String == "hi group")
            // alice turns on disappearing messages: a signed single change for the next revision.
            let ts2 = TestClock.next()
            let modified = try await c.server.json("modifyGroupTimer", ["groupId": groupId, "seconds": 3600, "timestamp": ts2])
            try await c.eventually("timer applied") { db in
                (try GroupStore.find(db, groupId: GroupKeys(masterKey: masterKey).groupId)?.state?.expireTimer) == 3600
            }
            let after = try #require(try await Self.groupState(c, masterKey))
            #expect(after.revision == modified["revision"] as? Int)
            let timerNotes = try await c.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE type = 'timer-notification'") ?? 0
            }
            #expect(timerNotes == 1)
            // Endorsements came with the logs.
            let endorsements = try await c.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM groupSendMemberEndorsement") ?? 0
            }
            #expect(endorsements == 2)
        }
    }

    /// Desktop writes to a group of three: the two other members are endorsed, so the message
    /// goes out once, sender-key encrypted and sealed for both, after a sender key
    /// distribution message to each.
    @Test func sendsWithSenderKey() async throws {
        try await LinkedClient.with { c in
            let bob = try await c.server.json("addAccount", ["name": "bob"])
            let bobAci = try #require(bob["aci"] as? String).lowercased()
            let g = try await c.server.json("createGroup", ["title": "Three", "members": ["alice", "phone", "bob"]])
            let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
            _ = try await c.server.json("sendGroupText", ["groupId": groupId, "text": "welcome", "timestamp": TestClock.next()])
            _ = try await c.log.waitFor("group update") { if case .other("groupUpdated", _) = $0 { return true } else { return false } }
            let state = try #require(try await Self.groupState(c, masterKey))
            #expect(state.membersV2.count == 3 && state.isMember(bobAci))

            let (messageId, ts) = try await c.messenger.sendGroupMessage("hello both", masterKey: masterKey)
            for name in ["alice", "bob"] {
                let m = try await c.server.json("waitForMessage", ["account": name])
                #expect(m["body"] as? String == "hello both" && (m["timestamp"] as? Int).map(UInt64.init) == ts)
                #expect(m["groupId"] as? String == masterKey.base64EncodedString())
                #expect(m["envelopeType"] as? String == "SealedSender" && m["innerType"] as? String == "SenderKey")
            }
            try await c.eventually("sent to both") { db in
                guard let s = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) else { return false }
                let json = try MessageStore.jsonObject(s)
                let states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                return states.count == 2 && states.values.allSatisfy { $0["status"] as? String == "Sent" }
                    && (json["unidentifiedDeliveries"] as? [String])?.count == 2
            }
            let info = try await c.database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT json_extract(json, '$.senderKeyInfo.distributionId') FROM conversations WHERE type = 'group'")
            }
            #expect(info != nil)
        }
    }

    /// Desktop creates a group with alice (whose profile key it learnt from her message), then
    /// renames it: alice gets both updates and the server state follows.
    @Test func createsAndModifiesAGroup() async throws {
        try await LinkedClient.with { c in
            _ = try await c.server.json("sendText", ["from": "alice", "text": "here's my key", "timestamp": TestClock.next(), "withProfileKey": true])
            _ = try await c.log.waitFor { if case .message = $0 { return true } else { return false } }
            let keys = try await c.groups.create(title: "Ours", members: [c.aliceAci])
            let created = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(created["groupId"] as? String == keys.masterKey.base64EncodedString())
            let adopted = try await c.server.json("adoptGroup", ["masterKey": keys.masterKey.base64EncodedString()])
            let groupId = try #require(adopted["id"] as? String)
            var server = try await c.server.json("groupState", ["groupId": groupId, "wait": false])
            #expect(server["title"] as? String == "Ours")
            #expect(Set((server["members"] as? [String] ?? []).map { $0.lowercased() }) == [c.aliceAci, c.phoneAci])

            try await c.groups.setTitle(keys, "Renamed")
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            server = try await c.server.json("groupState", ["groupId": groupId])
            #expect(server["title"] as? String == "Renamed" && server["revision"] as? Int == 1)
            let local = try #require(try await Self.groupState(c, keys.masterKey))
            #expect(local.name == "Renamed" && local.revision == 1 && local.isAdmin(c.phoneAci))
            let changes = try await c.database.pool.read { db in
                try String.fetchAll(db, sql: "SELECT json_extract(json, '$.groupV2Change.details[0].type') FROM messages WHERE type = 'group-v2-change' ORDER BY received_at")
            }
            #expect(changes == ["create", "title"])
        }
    }

    /// A link anyone can use: Desktop joins directly and ends up with the full state.
    @Test func joinsViaLink() async throws {
        try await LinkedClient.with { c in
            let g = try await c.server.json("createGroup", ["title": "Linked", "members": ["alice"], "link": "any"])
            let link = GroupLink(masterKey: Data(base64Encoded: g["masterKey"] as! String)!, inviteLinkPassword: Data(base64Encoded: g["inviteLinkPassword"] as! String)!)
            let parsed = try GroupLink(url: link.url)
            #expect(parsed == link)
            let info = try await c.groups.preJoinInfo(parsed)
            #expect(info.title == "Linked" && info.memberCount == 1 && !info.approvalRequired)
            let keys = try await c.groups.join(parsed)
            let state = try #require(try await Self.groupState(c, keys.masterKey))
            #expect(state.isMember(c.phoneAci) && state.isMember(c.aliceAci) && state.name == "Linked")
            let server = try await c.server.json("groupState", ["groupId": g["id"] as! String, "wait": false])
            #expect((server["members"] as? [String] ?? []).map { $0.lowercased() }.contains(c.phoneAci))
        }
    }

    /// A link that needs approval files a request instead.
    @Test func requestsToJoin() async throws {
        try await LinkedClient.with { c in
            let g = try await c.server.json("createGroup", ["title": "Gated", "members": ["alice"], "link": "admin"])
            let link = GroupLink(masterKey: Data(base64Encoded: g["masterKey"] as! String)!, inviteLinkPassword: Data(base64Encoded: g["inviteLinkPassword"] as! String)!)
            let keys = try await c.groups.join(link)
            let server = try await c.server.json("groupState", ["groupId": g["id"] as! String, "wait": false])
            #expect((server["requesting"] as? [String] ?? []).map { $0.lowercased() }.contains(c.phoneAci))
            let local = try #require(try await Self.groupState(c, keys.masterKey))
            #expect(local.isPendingApproval(c.phoneAci) && !local.isMember(c.phoneAci))
        }
    }
}

@Suite struct GroupAccessTests {
    /// Older production groups leave access fields UNKNOWN (0); upstream accepts it (DESKTOP-9868).
    @Test func unknownAccessIsValidLikeUpstream() {
        #expect(GroupAccess.isValid(GroupAccess.unknown) && GroupAccess.isValid(GroupAccess.member) && GroupAccess.isValid(GroupAccess.administrator))
        #expect(!GroupAccess.isValid(GroupAccess.any) && !GroupAccess.isValid(GroupAccess.unsatisfiable))
        #expect(GroupAccess.isValidLink(GroupAccess.unknown) && GroupAccess.isValidLink(GroupAccess.unsatisfiable) && !GroupAccess.isValidLink(GroupAccess.member))
    }
}

/// A group change that arrives inside a member's message is only as good as the group
/// server's signature on it (upstream getGroupUpdates / verifyNotarySignature).
@Suite struct GroupChangeSignatureTests {
    @Test func peerDeliveredChangeNeedsTheServersSignature() async throws {
        try await LinkedClient.with { c in
            let g = try await c.server.json("createGroup", ["title": "Mock club"])
            let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
            let keys = try GroupKeys(masterKey: masterKey)
            _ = try await c.server.json("sendGroupText", ["groupId": groupId, "text": "hi group", "timestamp": TestClock.next()])
            _ = try await c.log.waitFor("group update") { if case .other("groupUpdated", _) = $0 { return true } else { return false } }
            let before = try #require(try await GroupFlowTests.groupState(c, masterKey))
            let serverParams = try c.groupCredentials.serverParams()

            // A genuine change from the mock group server, as alice forwards it in her message.
            _ = try await c.server.json("modifyGroupTimer", ["groupId": groupId, "seconds": 3600, "timestamp": TestClock.next()])
            let event = try await c.log.waitFor("signed change") {
                if case .groupContext(_, let revision, let change, _, _) = $0 { return revision == before.revision + 1 && change != nil } else { return false }
            }
            guard case .groupContext(_, _, let signed?, _, _) = event else { throw HarnessError(description: "no group change") }
            #expect(try GroupsService.verifiedActions(signed, groupId: keys.groupId, serverParams: serverParams) != nil)

            // The same change, altered or misattributed: none of these counts.
            var change = try Signalservice_GroupChange(serializedBytes: signed)
            func verified(_ c: Signalservice_GroupChange, group: Data = keys.groupId, params: ServerPublicParams = serverParams) throws -> Bool {
                try GroupsService.verifiedActions(try c.serializedData(), groupId: group, serverParams: params) != nil
            }
            var tampered = change
            tampered.actions[tampered.actions.count - 1] ^= 0x01
            #expect(try !verified(tampered))
            tampered = change
            tampered.serverSignature[5] ^= 0x01
            #expect(try !verified(tampered))
            tampered = change
            tampered.serverSignature = Data()
            #expect(try !verified(tampered))
            tampered = change
            tampered.changeEpoch = UInt32(GroupsAPI.supportedChangeEpoch + 1)
            #expect(try !verified(tampered))
            #expect(try !verified(change, group: SignalCrypto.randomBytes(32)))                            // signed for another group
            #expect(try !verified(change, params: try ServerPublicParams(contents: SignalEnvironment.production.serverPublicParams)))   // another server
            #expect(try GroupsService.verifiedActions(Data([1, 2, 3]), groupId: keys.groupId, serverParams: serverParams) == nil)

            // A member forges the next revision (they hold the group keys, so they can encrypt
            // a new title) and sends it as if the server had accepted it.
            try await c.eventually("timer applied") { db in try GroupStore.find(db, groupId: keys.groupId)?.state?.expireTimer == 3600 }
            let current = try #require(try await GroupFlowTests.groupState(c, masterKey))
            var actions = Signalservice_GroupChange.Actions()
            actions.version = UInt32(current.revision + 1)
            actions.groupID = keys.groupId
            var title = Signalservice_GroupAttributeBlob()
            title.title = "Renamed by a forger"
            actions.modifyTitle.title = try GroupCipher(keys).encryptAttribute(title)
            change = Signalservice_GroupChange()
            change.actions = try actions.serializedData()
            change.serverSignature = SignalCrypto.randomBytes(64)
            let forged = try change.serializedData()
            _ = try? await c.groups.update(keys, newRevision: current.revision + 1, groupChange: forged)
            let after = try #require(try await GroupFlowTests.groupState(c, masterKey))
            #expect(after.name == "Mock club" && after.revision == current.revision)
        }
    }
}

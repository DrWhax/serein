// The chat events upstream records as they happen (ChatEventNotices) and their timeline
// notices: profile name changes, number changes, message request responses, ended polls,
// phone number discovery; and the stored kinds the history import writes.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite struct ChatEventNoticeTests {
    static func notices(_ db: SignalDatabase, _ conversationId: String) throws -> [TimelineNotice] {
        try db.pool.read { try ConversationQueries.messages($0, conversationId: conversationId, limit: 100) }.compactMap(\.notice)
    }

    /// The kinds the history import stores decode into notices; a pin and an ended poll find
    /// the message they point at.
    @Test func storedEntriesBecomeNotices() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        let (conversationId, target) = try db.pool.write { db throws -> (String, String) in
            let c = try MessageStore.privateConversation(db, serviceId: contact)
            let target = try MessageStore.insert(db, .init(conversationId: c, type: "incoming", body: "Tea or coffee?", sentAt: 1_000, source: contact,
                                                           sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            func notice(_ type: String, source: String? = nil, _ extra: [String: Any]) throws {
                try MessageStore.insert(db, .init(conversationId: c, type: type, body: "", sentAt: UInt64(MessageStore.now()), source: source,
                                                  sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false, extra: extra))
            }
            try notice("pinned-message-notification", source: contact, ["pinMessage": ["targetAuthorAci": contact, "targetSentTimestamp": 1_000]])
            try notice("poll-terminate", source: contact, ["pollTerminateNotification": ["question": "Tea or coffee?", "pollTimestamp": 1_000]])
            try notice("profile-change", ["changedId": c, "profileChange": ["type": "name", "oldName": "Ada", "newName": "Ada L"]])
            try notice("change-number-notification", source: contact, [:])
            try notice("joined-signal-notification", [:])
            try notice("title-transition-notification", ["titleTransition": ["renderInfo": ["type": "private", "e164": "+31612345678"]]])
            try notice("conversation-merge", ["conversationMerge": ["renderInfo": ["type": "private", "e164": "+31600000000"]]])
            try notice("phone-number-discovery", ["phoneNumberDiscovery": ["e164": "+31611111111"]])
            try notice("message-request-response-event", ["messageRequestResponseEvent": "ACCEPT"])
            try notice("universal-timer-notification", [:])
            try notice("contact-removed-notification", [:])
            try notice("incoming", source: contact, ["flags": 1])
            try notice("incoming", source: contact, ["requiredProtocolVersion": 99, "supportedVersionAtReceive": 8])
            try notice("incoming", source: contact, ["requiredProtocolVersion": 7, "supportedVersionAtReceive": 6])
            try notice("incoming", source: contact, ["requiredProtocolVersion": 7, "supportedVersionAtReceive": 7])   // supported: a message
            return (c, target)
        }
        let ref = TimelineMessageRef(author: contact, sentAt: 1_000, messageId: target)
        #expect(try Self.notices(db, conversationId) == [
            .pinnedMessage(source: contact, target: ref),
            .pollTerminate(source: contact, question: "Tea or coffee?", poll: ref),
            .profileChange(changedConversationId: conversationId, oldName: "Ada", newName: "Ada L"),
            .changeNumber(source: contact),
            .joinedSignal,
            .titleTransition(oldTitle: "+31612345678"),
            .conversationMerge(obsoleteTitle: "+31600000000", obsoleteNumber: "+31600000000"),
            .phoneNumberDiscovery(e164: "+31611111111"),
            .messageRequestResponse(event: "ACCEPT"),
            .universalTimer,
            .contactRemoved,
            .resetSession,
            .unsupported(canProcessNow: false),
            .unsupported(canProcessNow: true),
        ])
    }

    /// `maybeSetPendingUniversalTimer`: only a 1:1 chat with nothing said, no timer of its own and
    /// a universal timer set; once something is said, opening it removes the notice.
    @Test func universalTimerNotice() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        func open(_ c: String) throws -> Int {
            try db.pool.write { try ChatEventNotices.universalTimerOnOpen($0, conversationId: c) }
            return try Self.notices(db, c).filter { $0 == .universalTimer }.count
        }
        let (fresh, timed, signal, group) = try db.pool.write { db throws -> (String, String, String, String) in
            let fresh = try MessageStore.privateConversation(db, serviceId: UUID().uuidString.lowercased())
            let timed = try MessageStore.privateConversation(db, serviceId: UUID().uuidString.lowercased())
            try MessageStore.updateConversationJSON(db, conversationId: timed) { $0["expireTimer"] = 60 }
            let signal = try MessageStore.privateConversation(db, serviceId: StorageLocal.signalAci)
            let group = "group-\(UUID().uuidString)"
            try db.execute(sql: "INSERT INTO conversations (id, type, json) VALUES (?, 'group', ?)",
                           arguments: [group, try MessageStore.jsonString(["id": group, "type": "group"])])
            return (fresh, timed, signal, group)
        }
        #expect(try open(fresh) == 0)                                     // no universal timer
        try db.pool.write { try Items.set($0, "universalExpireTimer", 3600) }
        #expect(try open(fresh) == 1 && open(fresh) == 1)
        #expect(try open(timed) == 0 && open(signal) == 0 && open(group) == 0)
        _ = try db.pool.write { db in
            try MessageStore.insert(db, .init(conversationId: fresh, type: "incoming", body: "hi", sentAt: 1, source: nil, sourceDevice: 1,
                                              serverGuid: nil, serverTimestamp: nil, unidentified: false))
        }
        #expect(try open(fresh) == 0)
    }

    /// `maybeSetContactRemoved` / `maybeClearContactRemoved`: a removed contact's chat says so
    /// once; restored, the notice goes.
    @Test func contactRemovedNotice() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let c = try db.pool.write { try MessageStore.privateConversation($0, serviceId: UUID().uuidString.lowercased()) }
        func open(removal: String?) throws -> Int {
            try db.pool.write { db in
                try MessageStore.updateConversationJSON(db, conversationId: c) { $0["removalStage"] = removal }
                try ChatEventNotices.contactRemovedOnOpen(db, conversationId: c)
            }
            return try Self.notices(db, c).filter { $0 == .contactRemoved }.count
        }
        #expect(try open(removal: nil) == 0)
        #expect(try open(removal: "messageRequest") == 0)
        #expect(try open(removal: "justNotification") == 1 && open(removal: "justNotification") == 1)
        #expect(try open(removal: nil) == 0)
    }

    /// `showKeyTransparencyErrorDialog`: only when the self-check turns to failing.
    @Test func keyTransparencyErrorDialogIsDueOnceFailing() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        func record(_ old: KeyTransparencyHealth?, _ new: KeyTransparencyHealth?) throws -> Bool {
            try db.pool.write { db in
                try Items.remove(db, "keyTransparencyErrorPending")
                try KeyTransparencyService.recordSelfCheck(db, old: old, new: new)
                return try Items.get(db, "keyTransparencyErrorPending", as: Bool.self) ?? false
            }
        }
        #expect(try record(.intermittent, .fail))
        #expect(try record(nil, .fail))
        #expect(try record(.fail, .fail) == false)
        #expect(try record(.ok, .intermittent) == false)
        #expect(try record(.fail, .ok) == false)
        #expect(try db.pool.read { try Items.get($0, "keyTransparencySelfHealth", as: String.self) } == KeyTransparencyHealth.ok.rawValue)
    }

    /// `applyMessageRequestResponse`: accepting notes an accept (an unblock when blocked); a
    /// block and a spam report are noted when they change the state, and nothing twice.
    @Test func requestResponsesFollowUpstream() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let ourAci = UUID().uuidString.lowercased()
        func events(_ responses: [MessageRequestResponse]) throws -> [String] {
            let contact = UUID().uuidString.lowercased()
            let c = try db.pool.write { db throws -> String in
                let c = try MessageStore.privateConversation(db, serviceId: contact)
                for r in responses { try ConversationState.applyResponse(db, conversationId: c, r, ourAci: ourAci) }
                return c
            }
            return try Self.notices(db, c).compactMap { if case .messageRequestResponse(let e) = $0 { e } else { nil } }
        }
        #expect(try events([.accept]) == ["ACCEPT"])
        #expect(try events([.accept, .accept]) == ["ACCEPT"])
        #expect(try events([.block]) == ["BLOCK"])
        #expect(try events([.block, .accept]) == ["BLOCK", "UNBLOCK"])
        #expect(try events([.blockAndSpam]) == ["BLOCK", "SPAM"])
        #expect(try events([.spam, .blockAndSpam]) == ["SPAM", "BLOCK"])
        #expect(try events([.block, .blockAndSpam]) == ["BLOCK", "SPAM"])     // already blocked: no second block
        #expect(try events([.delete]) == [])
        // Upstream keeps the messages of a spam report; only deleting removes them.
        let kept = try db.pool.write { db throws -> Int in
            let c = try MessageStore.privateConversation(db, serviceId: UUID().uuidString.lowercased())
            try MessageStore.insert(db, .init(conversationId: c, type: "incoming", body: "hi", sentAt: 1, source: nil, sourceDevice: 1,
                                              serverGuid: nil, serverTimestamp: nil, unidentified: false))
            try ConversationState.applyResponse(db, conversationId: c, .blockAndSpam, ourAci: ourAci)
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type = 'incoming'", arguments: [c]) ?? 0
        }
        #expect(kept == 1)
    }

    /// A contact's new number is noted in their chat and in the groups we share with them,
    /// never for ourselves or a first number; a PNI chat that learns its ACI, after we had a
    /// session with the PNI, notes the discovery.
    @Test func numberChangesAndDiscovery() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let ourAci = UUID().uuidString.lowercased(), contact = UUID().uuidString.lowercased()
        let (chat, group) = try db.pool.write { db throws -> (String, String) in
            try Items.set(db, "uuid_id", "\(ourAci).2")
            let chat = try MessageStore.privateConversation(db, serviceId: contact)
            let group = "group-\(UUID().uuidString)"
            try db.execute(sql: "INSERT INTO conversations (id, type, json) VALUES (?, 'group', ?)",
                           arguments: [group, try MessageStore.jsonString(["id": group, "type": "group", "membersV2": [["aci": contact], ["aci": ourAci]]])])
            func sync(_ aci: String, _ number: String) throws {
                var d = Signalservice_ContactDetails()
                d.aci = aci
                d.number = number
                try ContactSync.apply(db, [d])
            }
            try sync(contact, "+31611111111")      // first number: nothing to note
            try sync(contact, "+31611111111")      // unchanged
            try sync(contact, "+31622222222")      // changed
            _ = try MessageStore.privateConversation(db, serviceId: ourAci)
            try sync(ourAci, "+31633333333")
            try sync(ourAci, "+31644444444")       // ours: never noted
            return (chat, group)
        }
        #expect(try Self.notices(db, chat) == [.changeNumber(source: contact)])
        #expect(try Self.notices(db, group) == [.changeNumber(source: contact)])
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE type = 'change-number-notification'") } == 2)

        let pni = "PNI:\(UUID().uuidString.lowercased())", aci = UUID().uuidString.lowercased()
        let discovered = try db.pool.write { db throws -> String in
            let c = try MessageStore.privateConversation(db, serviceId: pni)
            try db.execute(sql: "UPDATE conversations SET e164 = '+31655555555' WHERE id = ?", arguments: [c])
            try db.execute(sql: "INSERT INTO sessions (id, ourServiceId, serviceId, conversationId, deviceId, record) VALUES ('s', ?, ?, ?, 1, x'00')",
                           arguments: [ourAci, pni, c])
            return try StorageLocal.contactConversation(db, aci: aci, pni: pni, e164: "+31655555555")
        }
        #expect(try Self.notices(db, discovered) == [.phoneNumberDiscovery(e164: "+31655555555")])
        let noSession = try db.pool.write { db throws -> String in
            let p = "PNI:\(UUID().uuidString.lowercased())"
            let c = try MessageStore.privateConversation(db, serviceId: p)
            try db.execute(sql: "UPDATE conversations SET e164 = '+31666666666' WHERE id = ?", arguments: [c])
            return try StorageLocal.contactConversation(db, aci: UUID().uuidString.lowercased(), pni: p, e164: "+31666666666")
        }
        #expect(try Self.notices(db, noSession).isEmpty)
    }

    /// A fetched profile with a different name notes the change in the contact's chat and the
    /// groups we share; a first name, the same name or our own profile are not noted.
    @Test func profileNameChanges() async throws {
        try await LinkedClient.with { c in
            let ourAci = c.account.aci
            var keys: [String: IdentityKey] = [:]
            func store(_ serviceId: String, _ given: String?, _ family: String? = nil) async throws {
                let key = keys[serviceId] ?? IdentityKeyPair.generate().identityKey
                keys[serviceId] = key
                let p = SignalCore.Profile(serviceId: serviceId, givenName: given, familyName: family, about: nil, aboutEmoji: nil, avatarPath: nil,
                                           identityKey: key, sealedSender: .disabled, capabilities: [:])
                try await c.database.pool.write { try c.profiles.store($0, p) }
            }
            let contact = UUID().uuidString.lowercased()
            let group = try await c.database.pool.write { db throws -> String in
                let group = "group-\(UUID().uuidString)"
                try db.execute(sql: "INSERT INTO conversations (id, type, json) VALUES (?, 'group', ?)",
                               arguments: [group, try MessageStore.jsonString(["id": group, "type": "group", "membersV2": [["aci": contact]]])])
                return group
            }
            try await store(contact, "Ada")                 // first name
            try await store(contact, "Ada")                 // same
            try await store(contact, nil)                   // no name in the profile
            try await store(contact, "Ada", "Lovelace")     // changed
            try await store(ourAci, "Me")
            try await store(ourAci, "Still me")
            let chat = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: contact) }
            let change = TimelineNotice.profileChange(changedConversationId: chat, oldName: "Ada", newName: "Ada Lovelace")
            #expect(try Self.notices(c.database, chat).filter { if case .keyChange = $0 { false } else { true } } == [change])
            #expect(try Self.notices(c.database, group).filter { if case .keyChange = $0 { false } else { true } } == [change])
            let mine = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: ourAci) }
            #expect(try Self.notices(c.database, mine).isEmpty)
        }
    }

    /// Ending a poll notes it (unseen when someone else ended it); blocking and unblocking a
    /// chat note both.
    @Test func endedPollsAndBlocking() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["pollCreate": ["question": "Tea or coffee?", "options": ["tea", "coffee"], "allowMultiple": false]])
            _ = try await c.send(["pollTerminate": ["targetSentTimestamp": t]], storesMessage: false)
            let pollId = try await c.messageId(sentAt: t)
            let chat = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [pollId]) ?? "" }
            let ended = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: chat, limit: 50) }.filter { $0.notice != nil }
            #expect(ended.map(\.notice) == [.pollTerminate(source: c.aliceAci, question: "Tea or coffee?",
                                                           poll: TimelineMessageRef(author: c.aliceAci, sentAt: Int64(t), messageId: pollId))])
            #expect(ended.first?.isUnseen == true)

            try await c.messenger.setBlocked(chat, true)
            try await c.messenger.setBlocked(chat, true)
            try await c.messenger.setBlocked(chat, false)
            let events = try Self.notices(c.database, chat).compactMap { if case .messageRequestResponse(let e) = $0 { e } else { nil } }
            #expect(events == ["BLOCK", "UNBLOCK"])
        }
    }
}

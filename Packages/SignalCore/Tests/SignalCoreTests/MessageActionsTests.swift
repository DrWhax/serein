// The timeline message actions' backend: replies (quotes out and in), the timeline's reactions /
// quote / pin state, and the delete-for-everyone check — against the mock server.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct MessageActionsTests {
    @Test func repliesAndTimelineState() async throws {
        try await LinkedClient.with { c in
            let alice = c.aliceAci
            let ours = c.account.aci
            let t = try await c.send(["body": "tea?"])
            let teaId = try await c.messageId(sentAt: t)

            // Our reply quotes alice's message: id, author and text on the wire, the quote stored.
            let reply = try await c.messenger.sendMessage("yes please", attachments: [], quoting: teaId, to: alice)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let q = try #require(m["quote"] as? [String: Any])
            #expect(q["id"] as? Int == Int(t) && q["author"] as? String == alice && q["text"] as? String == "tea?")

            // Alice's reply to ours, with an attachment named in the quote.
            let r = try await c.send(["body": "coming up", "quote": ["id": reply.timestamp, "author": ours, "text": "yes please",
                                                                       "attachments": [["contentType": "image/jpeg", "fileName": "cup.jpg"]]]])

            try await c.messenger.react(to: teaId, emoji: "🫖")
            try await c.messenger.pin(teaId)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            _ = try await c.server.json("waitForMessage", ["account": "alice"])

            let conversationId = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [teaId]) }
            let timeline = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: try #require(conversationId)) }
            let tea = try #require(timeline.first { $0.id == teaId })
            #expect(tea.reactions.map(\.emoji) == ["🫖"] && tea.reactions.first?.fromId == ours)
            #expect(tea.isPinned)
            let ourReply = try #require(timeline.first { $0.id == reply.messageId })
            #expect(ourReply.quote?.authorAci == alice && ourReply.quote?.text == "tea?" && ourReply.quote?.messageId == teaId)
            let theirs = try #require(timeline.first { $0.sentAt == Int64(r) })
            #expect(theirs.quote?.authorAci == ours && theirs.quote?.messageId == reply.messageId)
            #expect(theirs.quote?.attachmentContentType == "image/jpeg" && theirs.quote?.attachmentFileName == "cup.jpg")

            // Delete for everyone: ours (sent) yes; alice's no; mixed no; too old no.
            let mine = try await c.messenger.canDeleteForEveryone([reply.messageId])
            #expect(mine.canDeleteForEveryone && !mine.needsAdminDelete && mine.isDeletingOwnMessages)
            #expect(try await c.messenger.canDeleteForEveryone([teaId]).canDeleteForEveryone == false)
            let mixed = try await c.messenger.canDeleteForEveryone([reply.messageId, teaId])
            #expect(!mixed.canDeleteForEveryone && !mixed.isDeletingOwnMessages)
            try await c.database.pool.write { db in
                try MessageStore.updateJSON(db, messageId: reply.messageId) { $0["serverTimestamp"] = MessageStore.now() - 3 * 86_400_000 }
            }
            #expect(try await c.messenger.canDeleteForEveryone([reply.messageId]).canDeleteForEveryone == false)

            // Message details: the recipient's state.
            let detail = try await c.database.pool.read { try ConversationQueries.deliveryDetail($0, messageId: reply.messageId) }
            #expect(detail?.recipients.count == 1 && detail?.recipients.first?.serviceId == alice && detail?.recipients.first?.status != "Pending")
        }
    }

    /// A reply to an image carries the image's thumbnail (uploaded with the quote), and shows it here.
    @Test func replyToImageCarriesThumbnail() async throws {
        try await LinkedClient.with { c in
            let image = AttachmentFlowTests.png()
            let (imageId, ts) = try await c.messenger.sendMessage("look", attachments: [OutgoingAttachment(data: image, contentType: "image/png", fileName: "a.png")],
                                                                  to: c.aliceAci)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            let reply = try await c.messenger.sendMessage("nice, right?", attachments: [], quoting: imageId, to: c.aliceAci)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let q = try #require(m["quote"] as? [String: Any])
            #expect(q["id"] as? Int == Int(ts))
            let qa = try #require((q["attachments"] as? [[String: Any]])?.first)
            #expect(qa["contentType"] as? String == "image/png" && qa["hasThumbnail"] as? Bool == true)
            let conversationId = try #require(try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [reply.messageId]) })
            let timeline = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversationId) }
            let quote = try #require(timeline.first { $0.id == reply.messageId }?.quote)
            #expect(quote.messageId == imageId && quote.thumbnail?.isDownloaded == true && quote.thumbnail?.contentType == "image/png")
        }
    }

    /// The details panel's data follows the chat's state; the media list has its attachments.
    @Test func detailsAndMedia() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "hi"])
            let id = try #require(try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) })
            func details() async throws -> ConversationDetailsInfo { try #require(try await c.database.pool.read { try ConversationQueries.details($0, conversationId: id) }) }
            var d = try await details()
            #expect(!d.isGroup && d.serviceId == c.aliceAci && d.muteExpiresAt == nil && !d.isBlocked && !d.isArchived && !d.hasMedia)
            try await c.messenger.setMuted(id, until: MessageStore.now() + 3_600_000)
            try await c.messenger.setPinned(id, true)
            try await c.messenger.setNotifyWhileMuted(id, calls: true, mentions: false, replies: true)
            try await c.messenger.setDisappearingTimer(id, seconds: 3600)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            d = try await details()
            #expect((d.muteExpiresAt ?? 0) > MessageStore.now() && d.isPinned && d.expireTimer == 3600)
            #expect(d.notifyForCallsIfMuted == true && d.notifyForMentionsIfMuted == false && d.notifyForRepliesIfMuted == true)
            try await c.messenger.setBlocked(id, true)
            #expect(try await details().isBlocked)

            let image = AttachmentFlowTests.png()
            let sent = try await c.messenger.sendMessage("pic", attachments: [OutgoingAttachment(data: image, contentType: "image/png", fileName: "a.png")], to: c.aliceAci)
            let media = try await c.database.pool.read { try ConversationQueries.media($0, conversationId: id) }
            #expect(media.count == 1 && media.first?.messageId == sent.messageId && media.first?.attachment.contentType == "image/png" && media.first?.outgoing == true)
            #expect(try await details().hasMedia)
        }
    }

    @Test func searchMessages() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "Tea time at five?"])
            _ = try await c.send(["body": "coffee instead"])
            let id = try #require(try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) })
            let hits = try await c.database.pool.read { try ConversationQueries.searchMessages($0, query: "te") }
            #expect(hits.map(\.body) == ["Tea time at five?"] && hits.first?.snippet.contains("<<left>>Tea<<right>>") == true)
            #expect(try await c.database.pool.read { try ConversationQueries.searchMessages($0, query: "coffee", conversationId: id) }.count == 1)
            #expect(try await c.database.pool.read { try ConversationQueries.searchMessages($0, query: "coffee", conversationId: "other") }.isEmpty)
            #expect(try await c.database.pool.read { try ConversationQueries.searchMessages($0, query: "  \" ") }.isEmpty)
        }
    }

    @Test func chatColors() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["body": "hi"])
            let id = try #require(try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) })
            let state = try await c.database.pool.write { db -> (ChatColorsState, ChatBubbleColor?, ChatBubbleColor?, ChatBubbleColor?) in
                #expect(try ChatColors.conversationColor(db, conversationId: id) == nil)
                try ChatColors.setConversationColor(db, conversationId: id, .preset("crimson"))
                let preset = try ChatColors.conversationColor(db, conversationId: id)
                let custom = try ChatColors.addCustomColor(db, solid: nil, gradient: (0xFF11_2233, 0xFF44_5566, 45))
                try ChatColors.setConversationColor(db, conversationId: id, .custom(custom))
                let chosen = try ChatColors.conversationColor(db, conversationId: id)
                try ChatColors.setDefaultColor(db, .preset("teal"))
                try ChatColors.removeCustomColor(db, id: custom)
                return (try ChatColors.state(db), preset, chosen, try ChatColors.conversationColor(db, conversationId: id))
            }
            #expect(state.1 == .preset("crimson"))
            if case .custom? = state.2 {} else { Issue.record("custom colour not chosen") }
            #expect(state.0.customColors.isEmpty && state.0.defaultColor == .preset("teal"))
            #expect(state.3 == nil)   // the chat falls back to the default once its colour is removed
        }
    }

    /// A chat for someone found by username or number: created once, remembering how.
    @Test func directConversationForLookups() async throws {
        try await LinkedClient.with { c in
            let aci = UUID().uuidString.lowercased()
            let id = try await c.messenger.directConversation(serviceId: aci, username: "tea.42")
            #expect(try await c.messenger.directConversation(serviceId: aci) == id)
            let json = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [id]) }
            #expect(json?.contains("tea.42") == true)
            let title = try await c.database.pool.read { try ConversationQueries.conversation($0, id: id) }?.title
            #expect(title == "tea.42", "title \(String(describing: title))")
        }
    }

    /// The notification-profile menu's override: on until a time, then off.
    @Test func notificationProfileOverride() async throws {
        try await LinkedClient.with { c in
            try await c.database.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO notificationProfiles (id, name, emoji, color, createdAtMs, allowAllCalls, allowAllMentions, allowedMembersJson, scheduleEnabled)
                    VALUES ('p1', 'Focus', '🌙', 0, 1, 0, 0, '[]', 0)
                    """)
            }
            var state = try await c.database.pool.read { try NotificationProfiles.menuState($0) }
            #expect(state.profiles.map(\.name) == ["Focus"] && state.activeProfileId == nil)
            let end = MessageStore.now() + 3_600_000
            try await c.messenger.setNotificationProfileOverride(profileId: "p1", enabled: true, endsAt: end)
            state = try await c.database.pool.read { try NotificationProfiles.menuState($0) }
            #expect(state.activeProfileId == "p1" && state.enabledOverrideEndsAt == end)
            try await c.messenger.setNotificationProfileOverride(profileId: "p1", enabled: false, endsAt: nil)
            state = try await c.database.pool.read { try NotificationProfiles.menuState($0) }
            #expect(state.activeProfileId == nil)
        }
    }

    /// Settings → Notifications → While muted: the account defaults are saved and marked for
    /// the storage service (AccountRecord), other settings only saved.
    @Test func notifyWhileMutedDefaultsSync() async throws {
        try await LinkedClient.with { c in
            func pending() async throws -> Bool {
                try await c.database.pool.read { db in
                    let me = try StorageLocal.ourConversation(db, account: c.account)
                    let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [me]) ?? "{}"
                    return json.contains("\"needsStorageServiceSync\":true")
                }
            }
            try await c.database.pool.write { db in
                let me = try StorageLocal.ourConversation(db, account: c.account)
                try MessageStore.updateConversationJSON(db, conversationId: me) { $0["needsStorageServiceSync"] = false }
            }
            var s = try await c.database.pool.read { try NotificationSettings.load($0) }
            s.playSound.toggle()
            try await c.messenger.saveNotificationSettings(s)
            #expect(try await pending() == false)
            s.notifyForCallsIfMuted.toggle()
            try await c.messenger.saveNotificationSettings(s)
            #expect(try await pending())
            let saved = try await c.database.pool.read { try NotificationSettings.load($0) }
            #expect(saved == s)
        }
    }

    /// A failed message is sent again by `retrySend`: alice gets it, and it is no longer Failed.
    @Test func retryFailedSend() async throws {
        try await LinkedClient.with { c in
            let sent = try await c.messenger.sendMessage("first try", attachments: [], to: c.aliceAci)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            let id = sent.messageId
            func status() async throws -> String? {
                try await c.database.pool.read { db in
                    let conv = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]) ?? ""
                    return try String.fetchOne(db, sql: "SELECT json ->> ('$.sendStateByConversationId.\"' || ? || '\".status') FROM messages WHERE id = ?",
                                               arguments: [conv, id])
                }
            }
            try await c.eventually("sent") { db in
                let conv = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]) ?? ""
                return try String.fetchOne(db, sql: "SELECT json ->> ('$.sendStateByConversationId.\"' || ? || '\".status') FROM messages WHERE id = ?",
                                           arguments: [conv, id]) != "Pending"
            }
            // As a failed send leaves it.
            try await c.database.pool.write { db in
                try MessageStore.updateJSON(db, messageId: id) { json in
                    var states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                    for k in states.keys { states[k]?["status"] = "Failed" }
                    json["sendStateByConversationId"] = states
                    json["errors"] = [["name": "SendError", "message": "test"]]
                }
            }
            #expect(try await status() == "Failed")
            try await c.messenger.retrySend(messageId: id)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(m["body"] as? String == "first try")
            try await c.eventually("no longer failed") { db in
                let conv = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]) ?? ""
                let s = try String.fetchOne(db, sql: "SELECT json ->> ('$.sendStateByConversationId.\"' || ? || '\".status') FROM messages WHERE id = ?",
                                            arguments: [conv, id])
                return s != nil && s != "Failed" && s != "Pending"
            }
            #expect(try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT json ->> '$.errors' FROM messages WHERE id = ?", arguments: [id]) } == nil)
        }
    }

    /// Mentions and styles go out in DataMessage.bodyRanges, are stored, and come back in the
    /// timeline; ranges outside the body are dropped.
    @Test func sendsBodyRanges() async throws {
        try await LinkedClient.with { c in
            let body = "hi \u{FFFC} bold"
            let ranges = [MessageBodyRange(start: 3, length: 1, kind: .mention(aci: c.aliceAci)),
                          MessageBodyRange(start: 5, length: 4, kind: .style(1)),
                          MessageBodyRange(start: 50, length: 2, kind: .style(2))]
            let sent = try await c.messenger.sendMessage(body, attachments: [], bodyRanges: ranges, to: c.aliceAci)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let wire = try #require(m["bodyRanges"] as? [[String: Any]])
            #expect(wire.count == 2)
            #expect(wire[0]["start"] as? Int == 3 && wire[0]["length"] as? Int == 1 && wire[0]["mentionAci"] as? String == c.aliceAci)
            #expect(wire[1]["start"] as? Int == 5 && wire[1]["length"] as? Int == 4 && wire[1]["style"] as? Int == 1)
            let conversation = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [sent.messageId]) }
            let timeline = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation ?? "", limit: 10) }
            #expect(timeline.first { $0.id == sent.messageId }?.bodyRanges == Array(ranges.prefix(2)))
        }
    }

    /// Puts a group message in the state of a send to two members that has not got anywhere
    /// (`oldFailure`: plus the Failed entry under the group's own id that a send giving up
    /// used to write).
    func waiting(_ c: LinkedClient, _ messageId: String, oldFailure: Bool = false) async throws -> (group: String, members: [String]) {
        try await c.database.pool.write { db in
            let group = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [messageId]) ?? ""
            let members = [try MessageStore.privateConversation(db, serviceId: c.aliceAci),
                           try MessageStore.privateConversation(db, serviceId: "11111111-2222-4333-8444-555555555555")]
            try MessageStore.updateJSON(db, messageId: messageId) { json in
                var states: [String: [String: Any]] = [:]
                for m in members { states[m] = ["status": "Pending"] }
                if oldFailure { states[group] = ["status": "Failed"] }
                json["sendStateByConversationId"] = states
            }
            return (group, members)
        }
    }

    /// A group send that gives up fails for every member still waiting, so the message shows
    /// "Send failed" (and can be retried), not "sending" for good with no job left.
    @Test func failedGroupSendFailsItsMembers() async throws {
        try await LinkedClient.with { c in
            let keys = try await c.groups.create(title: "Ours", members: [])
            let sent = try await c.messenger.sendGroupMessage("hello", masterKey: keys.masterKey)
            try await c.jobs.waitUntilIdle()
            let (group, members) = try await waiting(c, sent.messageId)
            try await c.database.pool.write { db in try MessageStore.markFailed(db, messageId: sent.messageId, error: "test") }
            let (statuses, timeline) = try await c.database.pool.read { db in
                (try MessageStore.groupStatuses(db, messageId: sent.messageId),
                 try ConversationQueries.messages(db, conversationId: group, limit: 10).first { $0.id == sent.messageId })
            }
            #expect(statuses == Dictionary(uniqueKeysWithValues: members.map { ($0, "Failed") }), "every member fails, and only the members")
            #expect(timeline?.status == .failed)
        }
    }

    /// Before the queue starts, a message still "sending" with no job left (as a group send that
    /// gave up used to leave it: members Pending, a Failed entry under the group's own id) fails,
    /// so it can be retried; a message a job will still send is left alone.
    @Test func orphanedSendsFailAtStart() async throws {
        try await LinkedClient.with { c in
            let keys = try await c.groups.create(title: "Ours", members: [])
            let stuck = try await c.messenger.sendGroupMessage("stuck", masterKey: keys.masterKey)
            let queued = try await c.messenger.sendGroupMessage("queued", masterKey: keys.masterKey)
            try await c.jobs.waitUntilIdle()
            let (_, members) = try await waiting(c, stuck.messageId, oldFailure: true)
            _ = try await waiting(c, queued.messageId, oldFailure: true)
            let repaired = try await c.database.pool.write { db in try MessageStore.failOrphanedSends(db, queued: [queued.messageId]) }
            #expect(repaired == 1)
            let (stuckStates, queuedStates) = try await c.database.pool.read { db in
                (try MessageStore.groupStatuses(db, messageId: stuck.messageId), try MessageStore.groupStatuses(db, messageId: queued.messageId))
            }
            #expect(stuckStates == Dictionary(uniqueKeysWithValues: members.map { ($0, "Failed") }), "the group's own entry goes; the members fail")
            #expect(queuedStates.values.filter { $0 == "Pending" }.count == 2, "a queued message is not touched")
        }
    }

    /// A message to a group with only us has no one to wait for: it shows as sent, not
    /// "sending" forever (upstream `isMessageJustForMe`).
    @Test func messageToAGroupOfOneIsSent() async throws {
        try await LinkedClient.with { c in
            let keys = try await c.groups.create(title: "Just me", members: [])
            let sent = try await c.messenger.sendGroupMessage("note", masterKey: keys.masterKey)
            let conversation = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [sent.messageId]) }
            let m = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation ?? "", limit: 10).first { $0.id == sent.messageId } }
            #expect(m?.status == .sent)
        }
    }

    /// A poll we create shows in the timeline with its options; our vote is counted on it.
    @Test func pollInTheTimeline() async throws {
        try await LinkedClient.with { c in
            let conversation = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: c.aliceAci) }
            let id = try await c.messenger.createPoll(question: "Tea or coffee?", options: ["Tea", "Coffee"], allowMultiple: false, conversationId: conversation)
            _ = try await c.server.json("waitForMessage", ["account": "alice"])
            try await c.messenger.vote(on: id, optionIndexes: [1])
            let me = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: c.account.aci) }
            let poll = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation, limit: 10).first { $0.id == id }?.poll }
            #expect(poll?.question == "Tea or coffee?" && poll?.options == ["Tea", "Coffee"] && poll?.terminated == false)
            #expect(poll?.votes == [TimelinePoll.Vote(fromConversationId: me, optionIndexes: [1])])
        }
    }
}

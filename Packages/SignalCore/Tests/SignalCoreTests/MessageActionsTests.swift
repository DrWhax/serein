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
}

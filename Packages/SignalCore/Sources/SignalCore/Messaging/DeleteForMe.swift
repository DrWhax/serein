// SyncMessage.DeleteForMe (ts/messageModifiers/DeletesForMe.preload.ts and
// ts/util/deleteForMe.ts): messages, whole conversations (up to the newest messages the other
// device names) and single attachments deleted on another of our devices; and the sync we send
// for deletions made here.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

enum DeleteForMe {
    typealias ConversationIdentifier = Signalservice_ConversationIdentifier
    typealias AddressableMessage = Signalservice_AddressableMessage

    static func conversationId(_ db: Database, _ c: ConversationIdentifier) throws -> String? {
        switch c.identifier {
        case .threadServiceIDBinary(let b):
            guard let s = StorageLocal.serviceId(binary: b, string: "") else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [s])
        case .threadServiceID(let str):
            guard let s = StorageLocal.serviceId(binary: Data(), string: str) else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [s])
        case .threadGroupID(let g):
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [g.base64EncodedString()])
        case .threadE164(let e):
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND e164 = ?", arguments: [e])
        case .none:
            return nil
        }
    }

    static func messageId(_ db: Database, conversationId: String, _ m: AddressableMessage, ourAci: String) throws -> String? {
        var author: String?
        switch m.author {
        case .authorServiceIDBinary(let b): author = StorageLocal.serviceId(binary: b, string: "")
        case .authorServiceID(let s): author = StorageLocal.serviceId(binary: Data(), string: s)
        case .authorE164(let e):
            author = try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE type = 'private' AND e164 = ?", arguments: [e])
        case .none: author = nil
        }
        guard let author else { return nil }
        return try String.fetchOne(db, sql: "SELECT id FROM messages WHERE conversationId = ? AND sourceServiceId = ? AND sent_at = ?",
                                   arguments: [conversationId, author, Int64(m.sentTimestamp)])
    }

    static func deleteMessage(_ db: Database, _ id: String) throws {
        try MessageModifiers.erase(db, id)
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
    }

    static func apply(_ db: Database, _ d: Signalservice_SyncMessage.DeleteForMe, ourAci: String) throws {
        for md in d.messageDeletes {
            guard let c = try conversationId(db, md.conversation) else { continue }
            for m in md.messages { if let id = try messageId(db, conversationId: c, m, ourAci: ourAci) { try deleteMessage(db, id) } }
        }
        for cd in d.conversationDeletes {
            guard let c = try conversationId(db, cd.conversation) else { continue }
            // Everything up to the newest message the other device had (`deleteConversation`);
            // none of them here means nothing is deleted.
            let newest = try (cd.mostRecentMessages + cd.mostRecentNonExpiringMessages).compactMap { try messageId(db, conversationId: c, $0, ourAci: ourAci) }
                .compactMap { try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [$0]) }.max()
            guard let newest else { continue }
            for id in try String.fetchAll(db, sql: "SELECT id FROM messages WHERE conversationId = ? AND received_at <= ?", arguments: [c, newest]) {
                try deleteMessage(db, id)
            }
            if cd.isFullDelete {
                try MessageStore.updateConversationJSON(db, conversationId: c) { $0["active_at"] = nil; $0["isArchived"] = false }
                try db.execute(sql: "UPDATE conversations SET active_at = NULL WHERE id = ?", arguments: [c])
            }
        }
        for lc in d.localOnlyConversationDeletes {
            // Deleted only if nothing but local-only messages (notifications) remain.
            guard let c = try conversationId(db, lc.conversation),
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type IN ('incoming', 'outgoing')", arguments: [c]) == 0
            else { continue }
            for id in try String.fetchAll(db, sql: "SELECT id FROM messages WHERE conversationId = ?", arguments: [c]) { try deleteMessage(db, id) }
        }
        for ad in d.attachmentDeletes {
            guard let c = try conversationId(db, ad.conversation), let id = try messageId(db, conversationId: c, ad.targetMessage, ourAci: ourAci) else { continue }
            for (loc, a) in try MessageAttachments.fetch(db, messageId: id) {
                let matches = (ad.hasClientUuid && StorageLocal.uuidString(ad.clientUuid) == a.clientUuid)
                    || (ad.hasFallbackDigest && a.digest.flatMap { Data(base64Encoded: $0) } == ad.fallbackDigest)
                    || (ad.hasFallbackPlaintextHash && a.plaintextHash.flatMap { Data(hex: $0) } == ad.fallbackPlaintextHash)
                if matches {
                    try db.execute(sql: "DELETE FROM message_attachments WHERE messageId = ? AND attachmentType = ? AND orderInMessage = ?",
                                   arguments: [id, loc.type.rawValue, loc.order])
                }
            }
            try MessageAttachments.updateMessageFlags(db, messageId: id)
        }
    }

    // MARK: outgoing

    static func identifier(_ db: Database, conversationId: String) throws -> ConversationIdentifier? {
        guard let row = try Row.fetchOne(db, sql: "SELECT serviceId, groupId FROM conversations WHERE id = ?", arguments: [conversationId]) else { return nil }
        var c = ConversationIdentifier()
        if let g: String = row["groupId"], let d = Data(base64Encoded: g) { c.threadGroupID = d } else if let s: String = row["serviceId"],
            let b = StorageLocal.serviceIdBinary(s) { c.threadServiceIDBinary = b } else { return nil }
        return c
    }

    static func addressable(_ db: Database, messageId: String) throws -> AddressableMessage? {
        guard let row = try Row.fetchOne(db, sql: "SELECT sourceServiceId, sent_at FROM messages WHERE id = ?", arguments: [messageId]),
              let author: String = row["sourceServiceId"], let b = StorageLocal.serviceIdBinary(author) else { return nil }
        var m = AddressableMessage()
        m.authorServiceIDBinary = b
        m.sentTimestamp = UInt64(row["sent_at"] as Int64)
        return m
    }
}

// The sticker of a received (or synced sent) DataMessage: `processDataMessage` validation, the
// message's `sticker` attribute, its `sticker` attachment (a copy of the local sticker when the
// pack is here, else the pointer, queued for download) and the pack reference (`savePackMetadata`).

import Foundation
import GRDB
import SignalProtos

extension MessageStore {
    /// Returns false (and stores nothing) for an invalid sticker, which upstream drops.
    @discardableResult
    static func storeSticker(_ db: Database, messageId: String, conversationId: String, sentAt: Int64, messageType: String,
                             _ s: Signalservice_DataMessage.Sticker) throws -> Bool {
        guard s.packID.count == 16, s.packKey.count == 32, s.hasData else { return false }
        let packId = s.packID.hexString, packKey = s.packKey.base64EncodedString(), stickerId = Int(s.stickerID)
        try updateJSON(db, messageId: messageId) { json in
            var sticker: [String: Any] = ["packId": packId, "stickerId": stickerId, "packKey": packKey]
            if s.hasEmoji { sticker["emoji"] = s.emoji }
            json["sticker"] = sticker
        }
        let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? now()
        let status = try Stickers.status(db, packId)
        let stored = try Stickers.localSticker(db, packId: packId, stickerId: stickerId) != nil
        let haveLocal = (status == .downloaded || status == .installed) && stored
        var a = MessageAttachment(pointer: s.data)
        let accepted = try isAcceptedForDownloads(db, conversationId: conversationId)
        let queue = !haveLocal && accepted
        a.pending = queue
        let loc = MessageAttachments.Location(messageId: messageId, type: .sticker, order: 0)
        try MessageAttachments.upsert(db, loc, conversationId: conversationId, sentAt: sentAt, receivedAt: receivedAt, messageType: messageType, a)
        if queue {
            try AttachmentDownloads.add(db, AttachmentDownloadJob(messageId: messageId, attachmentType: .sticker, signature: a.signature,
                                                                  receivedAt: receivedAt, sentAt: sentAt, attachment: a))
        }
        try Stickers.savePackMetadata(db, packId: packId, packKey: packKey, messageId: messageId, stickerId: stickerId, isUnresolved: true)
        if haveLocal { try JobQueue.insert(db, queueType: StickerReferenceJob.queueType, payload: StickerReferenceJob(packId: packId)) }
        try MessageAttachments.updateMessageFlags(db, messageId: messageId)
        return true
    }
}

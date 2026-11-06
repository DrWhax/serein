// Incoming attachment pointers → message_attachments rows, and their download jobs
// (handleAttachmentDownloadsForNewMessage / queueAttachmentDownloads).

import Foundation
import GRDB
import SignalProtos

extension MessageStore {
    /// Whether downloads may start without the user asking: the conversation is accepted (no
    /// pending message request). Message requests land with step 6; until then, all are.
    static func isAcceptedForDownloads(_ db: Database, conversationId: String) throws -> Bool {
        // Media in a message request is downloaded only once it is accepted.
        guard let uuidId: String = try Items.get(db, "uuid_id"), let aci = uuidId.split(separator: ".").first.map(String.init) else { return false }
        return try ConversationState.isAccepted(db, conversationId: conversationId, ourAci: aci)
    }

    static func storeIncomingAttachments(_ db: Database, messageId: String, conversationId: String, sentAt: Int64,
                                         attachments: [Signalservice_AttachmentPointer], type: MessageAttachmentType = .attachment) throws {
        guard !attachments.isEmpty else { return }
        let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? now()
        let settings = try AttachmentPolicy.autoDownload(db)
        let maxAuto = try AttachmentPolicy.maximumAutoDownloadSize(db)
        let accepted = try isAcceptedForDownloads(db, conversationId: conversationId)
        for (i, pointer) in attachments.enumerated() {
            var a = MessageAttachment(pointer: pointer)
            let queue = accepted && AttachmentPolicy.shouldAutoDownload(a, type: type, settings: settings, maxAutoDownload: maxAuto)
            a.pending = queue
            let loc = MessageAttachments.Location(messageId: messageId, type: type, order: i)
            try MessageAttachments.upsert(db, loc, conversationId: conversationId, sentAt: sentAt, receivedAt: receivedAt, messageType: "incoming", a)
            if queue {
                try AttachmentDownloads.add(db, AttachmentDownloadJob(messageId: messageId, attachmentType: type, signature: a.signature,
                                                                      receivedAt: receivedAt, sentAt: sentAt, attachment: a))
            }
        }
        try MessageAttachments.updateMessageFlags(db, messageId: messageId)
    }

    /// A manual download ("Download" in the UI): queues the attachment whatever the settings.
    public static func queueDownload(_ db: Database, _ loc: MessageAttachments.Location) throws {
        guard var a = try MessageAttachments.fetch(db, loc), !a.isDownloaded,
              let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at, type FROM messages WHERE id = ?", arguments: [loc.messageId])
        else { return }
        a.pending = true
        a.error = nil
        try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                      messageType: row["type"] ?? "incoming", a)
        try AttachmentDownloads.add(db, AttachmentDownloadJob(messageId: loc.messageId, attachmentType: loc.type, signature: a.signature,
                                                              receivedAt: row["received_at"], sentAt: row["sent_at"], attachment: a))
    }
}

// Long message bodies on send (ts/util/longAttachment.std.ts, Message2 migrateBodyAttachmentToDisk,
// sendNormalMessage): a body over MAX_MESSAGE_BODY_BYTE_LENGTH travels trimmed, with the whole
// text as a text/x-signal-plain attachment first among the attachments. Receivers drop a longer
// body ("Dropping too-long message"), so it must never go out whole.

import Foundation
import GRDB
import SignalProtos

public enum LongText {
    /// `LONG_MESSAGE`
    public static let contentType = "text/x-signal-plain"
    /// `MAX_MESSAGE_BODY_BYTE_LENGTH`
    public static let maxBodyBytes = InboundLimits.maxBodyBytes
    /// `MAX_PLAINTEXT_BODY_ATTACHMENT_BYTE_LENGTH`: a longer body is not sent.
    public static let maxAttachmentBytes = 64 << 10

    public static func isTooLong(_ body: String) -> Bool { InboundLimits.bodyTooLong(body) }

    /// `trimBody` (unicodeSlice): the leading whole graphemes that fit in the limit; U+FFFE when
    /// not even the first one does.
    public static func trim(_ body: String, maxBytes: Int = maxBodyBytes) -> String {
        guard body.utf8.count > maxBytes else { return body }
        var bytes = 0
        var end = body.startIndex
        for i in body.indices {
            let n = body[i].utf8.count
            guard bytes + n <= maxBytes else { break }
            bytes += n
            end = body.index(after: i)
        }
        return end == body.startIndex ? "\u{FFFE}" : String(body[..<end])
    }
}

public enum LongTextError: Error, Equatable {
    case tooLong(Int)
}

extension Messenger {
    /// The body and leading attachment pointers for an outgoing message: unchanged when it
    /// fits, otherwise trimmed, with the whole text stored as the message's `long-message`
    /// attachment (its bodyAttachment) and uploaded (or its pointer reused within 3 days).
    func outgoingBody(messageId: String, body: String) async throws -> (body: String, attachments: [Signalservice_AttachmentPointer]) {
        guard LongText.isTooLong(body) else { return (body, []) }
        let loc = MessageAttachments.Location(messageId: messageId, type: .longMessage, order: 0)
        if try await database.pool.read({ db in try MessageAttachments.fetch(db, loc) }) == nil {
            let a = try await prepareLongText(body)
            try await database.pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at FROM messages WHERE id = ?", arguments: [messageId])
                else { return }
                try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                              messageType: "outgoing", a)
            }
        }
        let pointers = try await uploadAttachments(messageId: messageId, type: .longMessage)
        return (LongText.trim(body), pointers)
    }

    /// For a body sent once, not kept as an attachment of its own (edits, story replies): the
    /// trimmed body and the uploaded pointer of the whole text.
    func outgoingBody(_ body: String) async throws -> (body: String, attachments: [Signalservice_AttachmentPointer]) {
        guard LongText.isTooLong(body) else { return (body, []) }
        guard let services = attachments else { throw JobError.permanent("no attachment services") }
        let uploaded = try await services.upload(try await prepareLongText(body))
        return (LongText.trim(body), [uploaded.pointer()])
    }

    private func prepareLongText(_ body: String) async throws -> MessageAttachment {
        let text = Data(body.utf8)
        guard text.count <= LongText.maxAttachmentBytes else { throw JobError.permanent("\(LongTextError.tooLong(text.count))") }
        guard let services = attachments else { throw JobError.permanent("no attachment services") }
        return try await services.prepare(OutgoingAttachment(data: text, contentType: LongText.contentType), transcode: false)
    }
}

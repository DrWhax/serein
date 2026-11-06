// Replies (`quote` in DataMessage; upstream ts/util/makeQuote.preload.ts): the quoted message's
// reference — its timestamp and author, its text and body ranges, its attachments' types and
// names — stored on the outgoing message as `json.quote` (the shape the receiver stores),
// and sent from there by both send paths.

import Foundation
import GRDB
import SignalProtos

extension Messenger {
    /// An outgoing message's extra JSON, with the quote of `quoting` (a message id) if any.
    static func outgoingExtra(_ db: Database, _ extra: [String: Any], quoting: String?, ourAci: String) throws -> [String: Any] {
        var out = extra
        if let quoting, let q = try quoteJSON(db, quoting: quoting, ourAci: ourAci) { out["quote"] = q }
        return out
    }

    /// `makeQuote`: the stored quote for a reply to `messageId` (nil when it is gone).
    static func quoteJSON(_ db: Database, quoting messageId: String, ourAci: String) throws -> [String: Any]? {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, sent_at, sourceServiceId, body, json FROM messages WHERE id = ?", arguments: [messageId])
        else { return nil }
        let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
        guard json["deletedForEveryone"] as? Bool != true else { return nil }
        let outgoing = (row["type"] as String?) == "outgoing"
        guard let author = outgoing ? ourAci : row["sourceServiceId"] as String? else { return nil }
        var quote: [String: Any] = ["id": row["sent_at"] as Int64? ?? 0, "authorAci": author, "isGiftBadge": false, "referencedMessageNotFound": false]
        if let body = row["body"] as String?, !body.isEmpty { quote["text"] = body }
        if let ranges = json["bodyRanges"] as? [[String: Any]], !ranges.isEmpty { quote["bodyRanges"] = ranges }
        let attachments = try MessageAttachments.fetch(db, messageId: messageId)
            .filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }
            .sorted { $0.0.order < $1.0.order }
        // Upstream quotes the first attachment.
        quote["attachments"] = attachments.prefix(1).map { a -> [String: Any] in
            var q: [String: Any] = ["contentType": a.1.contentType]
            if let name = a.1.fileName { q["fileName"] = name }
            return q
        }
        return quote
    }

    /// `makeQuote`'s thumbnail: a small PNG of the quoted image (or the video's stored
    /// thumbnail), encrypted at rest like any outgoing attachment; stored as the reply's
    /// `quote` attachment and uploaded with it.
    func prepareQuoteThumbnail(_ quoting: String?) async -> MessageAttachment? {
        guard let quoting, let services = attachments else { return nil }
        let first = try? await database.pool.read { db in
            try MessageAttachments.fetch(db, messageId: quoting).filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }.min { $0.0.order < $1.0.order }?.1
        }
        guard let a = first ?? nil, AttachmentPolicy.isImage(a.contentType) || AttachmentPolicy.isVideo(a.contentType) else { return nil }
        var png = a.thumbnail.flatMap { t in try? services.store.plaintext(of: LocalFile(path: t.path, localKey: t.localKey, size: t.size)) }
        if png == nil, AttachmentPolicy.isImage(a.contentType), let media = services.media, let bytes = (try? services.store.plaintext(of: a)) ?? nil {
            png = try? await media.thumbnail(bytes, size: 150).png
        }
        guard let png else { return nil }
        return try? await services.prepare(OutgoingAttachment(data: png, contentType: "image/png", fileName: nil), transcode: false)
    }

    /// Stores a reply's quote thumbnail (inside the reply's insert).
    static func storeQuoteThumbnail(_ db: Database, _ t: MessageAttachment?, messageId: String, conversationId: String, sentAt: UInt64) throws {
        guard let t else { return }
        let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
        try MessageAttachments.upsert(db, .init(messageId: messageId, type: .quote, order: 0), conversationId: conversationId, sentAt: Int64(sentAt),
                                      receivedAt: receivedAt, messageType: "outgoing", t)
    }

    /// The DataMessage quote of an outgoing message (from its `json.quote`).
    func quoteProto(messageId: String) async throws -> Signalservice_DataMessage.Quote? {
        guard let s = try await database.pool.read({ try String.fetchOne($0, sql: "SELECT json ->> '$.quote' FROM messages WHERE id = ?", arguments: [messageId]) }),
              let q = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let author = q["authorAci"] as? String, let id = (q["id"] as? NSNumber)?.uint64Value else { return nil }
        var out = Signalservice_DataMessage.Quote()
        out.id = id
        out.authorAciBinary = StorageLocal.uuidBytes(author) ?? Data()
        out.type = .normal
        if let text = q["text"] as? String { out.text = text }
        for a in q["attachments"] as? [[String: Any]] ?? [] {
            var qa = Signalservice_DataMessage.Quote.QuotedAttachment()
            if let t = a["contentType"] as? String { qa.contentType = t }
            if let n = a["fileName"] as? String { qa.fileName = n }
            out.attachments.append(qa)
        }
        if let ranges = q["bodyRanges"] as? [[String: Any]] { out.bodyRanges = Self.bodyRangeProtos(ranges) }
        if !out.attachments.isEmpty, let thumb = try await uploadAttachments(messageId: messageId, type: .quote).first { out.attachments[0].thumbnail = thumb }
        return out
    }

    /// Stored body ranges (`{start, length, style | mentionAci}`) as protos.
    static func bodyRangeProtos(_ ranges: [[String: Any]]) -> [Signalservice_BodyRange] {
        ranges.compactMap { r in
            guard let start = (r["start"] as? NSNumber)?.uint32Value, let length = (r["length"] as? NSNumber)?.uint32Value else { return nil }
            var b = Signalservice_BodyRange()
            b.start = start
            b.length = length
            if let aci = r["mentionAci"] as? String, let bytes = StorageLocal.uuidBytes(aci) {
                b.mentionAciBinary = bytes
            } else if let style = (r["style"] as? NSNumber)?.intValue, let s = Signalservice_BodyRange.Style(rawValue: style) {
                b.style = s
            } else {
                return nil
            }
            return b
        }
    }
}

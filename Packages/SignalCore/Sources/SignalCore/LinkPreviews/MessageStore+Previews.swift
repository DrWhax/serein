// DataMessage.preview on received and synced messages (`getValidLinkPreviews`): only previews
// whose URL is previewable and appears in the body are kept, as the message's `preview`
// attribute; their images are `preview` attachments, queued like other media.

import Foundation
import GRDB
import SignalProtos
import SignalText

extension MessageStore {
    static func previewJSON(url: String, title: String?, description: String?, date: Int64?) -> [String: Any] {
        var p: [String: Any] = ["url": url]
        if let title, !title.isEmpty { p["title"] = title }
        if let description, !description.isEmpty { p["description"] = description }
        if let date, date > 0 { p["date"] = date }
        if let domain = LinkPreviewRules.domain(url) { p["domain"] = domain }
        if LinkPreviewRules.stickerPack(url) != nil { p["isStickerPack"] = true }
        if LinkPreviewRules.isCallLink(url) { p["isCallLink"] = true }
        return p
    }

    @discardableResult
    static func storePreviews(_ db: Database, messageId: String, conversationId: String, sentAt: Int64, messageType: String, body: String,
                              _ previews: [Signalservice_Preview], isStory: Bool = false) throws -> Int {
        guard !previews.isEmpty else { return 0 }
        let urls = LinkPreviewRules.findLinks(body)
        let valid = previews.filter { LinkPreviewRules.isValidLinkPreview(url: $0.url, urlsInBody: urls, isStory: isStory) }
        guard !valid.isEmpty else { return 0 }
        try updateJSON(db, messageId: messageId) { json in
            json["preview"] = valid.map { p in
                previewJSON(url: p.url, title: p.hasTitle ? p.title : nil, description: p.hasDescription_p ? p.description_p : nil,
                            date: p.hasDate ? Int64(clamping: p.date) : nil)
            }
        }
        let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? now()
        let settings = try AttachmentPolicy.autoDownload(db)
        let maxAuto = try AttachmentPolicy.maximumAutoDownloadSize(db)
        let accepted = try isAcceptedForDownloads(db, conversationId: conversationId)
        for (i, p) in valid.enumerated() where p.hasImage {
            var a = MessageAttachment(pointer: p.image)
            let queue = accepted && AttachmentPolicy.shouldAutoDownload(a, type: .preview, settings: settings, maxAutoDownload: maxAuto)
            a.pending = queue
            let loc = MessageAttachments.Location(messageId: messageId, type: .preview, order: i)
            try MessageAttachments.upsert(db, loc, conversationId: conversationId, sentAt: sentAt, receivedAt: receivedAt, messageType: messageType, a)
            if queue {
                try AttachmentDownloads.add(db, AttachmentDownloadJob(messageId: messageId, attachmentType: .preview, signature: a.signature,
                                                                      receivedAt: receivedAt, sentAt: sentAt, attachment: a))
            }
        }
        try MessageAttachments.updateMessageFlags(db, messageId: messageId)
        return valid.count
    }
}

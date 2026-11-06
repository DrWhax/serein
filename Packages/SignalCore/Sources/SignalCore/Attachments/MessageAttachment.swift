// An attachment as upstream keeps it (ts/types/Attachment.std.ts AttachmentType), its
// AttachmentPointer conversions (ts/textsecure/processDataMessage + sendMessage), and the
// message_attachments rows that persist it (ts/sql/Server.node.ts, schema 1300+).

import Foundation
import GRDB
import SignalProtos

/// `message_attachments.attachmentType`
public enum MessageAttachmentType: String, Codable, Sendable, CaseIterable {
    case attachment
    case longMessage = "long-message"
    case quote
    case preview
    case contact
    case sticker
}

public struct MessageAttachment: Codable, Sendable, Equatable {
    public var contentType: String
    public var size: Int
    // Transit (CDN) fields.
    public var cdnKey: String?
    public var cdnNumber: Int?
    /// Base64 64-byte key.
    public var key: String?
    /// Base64 SHA-256 of the transit blob.
    public var digest: String?
    public var incrementalMac: String?
    public var chunkSize: Int?
    public var uploadTimestamp: UInt64?
    // Metadata.
    public var fileName: String?
    public var flags: Int?
    public var width: Int?
    public var height: Int?
    public var caption: String?
    public var blurHash: String?
    public var clientUuid: String?
    // Local copy (after download).
    public var path: String?
    public var localKey: String?
    public var version: Int?
    public var plaintextHash: String?
    // State.
    public var pending: Bool?
    public var error: Bool?
    public var wasTooBig: Bool?
    public var thumbnail: LocalFile?
    /// A video's first frame (PNG, display size).
    public var screenshot: LocalFile?
    /// A video's (or audio's) length in seconds.
    public var duration: Double?

    /// A locally stored derivative (thumbnail / screenshot).
    public struct LocalFile: Codable, Sendable, Equatable {
        public var path: String
        public var localKey: String
        public var size: Int
        public var contentType: String
        public var width: Int?
        public var height: Int?
        public var version: Int = 2
    }

    public init(contentType: String, size: Int) {
        self.contentType = contentType
        self.size = size
    }

    // Upstream's AttachmentPointer flags.
    public static let flagVoiceMessage = 1
    public static let flagBorderless = 2
    public static let flagGif = 8

    public var isVoiceMessage: Bool { (flags ?? 0) & Self.flagVoiceMessage != 0 }
    public var isDownloaded: Bool { path != nil && localKey != nil }

    /// `getUndownloadedAttachmentSignature`
    public var signature: String { "\(digest ?? "").\(plaintextHash ?? "")" }

    /// `processAttachment`: an incoming pointer.
    public init(pointer p: Signalservice_AttachmentPointer) {
        self.init(contentType: p.hasContentType ? p.contentType : "application/octet-stream", size: Int(p.size))
        switch p.attachmentIdentifier {
        case .cdnKey(let k): cdnKey = k
        case .cdnID(let id): cdnKey = id == 0 ? nil : String(id)
        case nil: break
        }
        cdnNumber = p.hasCdnNumber ? Int(p.cdnNumber) : 0
        key = p.hasKey ? p.key.base64EncodedString() : nil
        digest = p.hasDigest ? p.digest.base64EncodedString() : nil
        incrementalMac = p.hasIncrementalMac && !p.incrementalMac.isEmpty ? p.incrementalMac.base64EncodedString() : nil
        chunkSize = p.hasChunkSize && p.chunkSize > 0 ? Int(p.chunkSize) : nil
        uploadTimestamp = p.hasUploadTimestamp ? p.uploadTimestamp : nil
        fileName = p.hasFileName ? p.fileName : nil
        flags = p.hasFlags ? Int(p.flags) : nil
        width = p.hasWidth ? Int(p.width) : nil
        height = p.hasHeight ? Int(p.height) : nil
        caption = p.hasCaption ? p.caption : nil
        blurHash = p.hasBlurHash ? p.blurHash : nil
        clientUuid = p.hasClientUuid ? UUID(data: p.clientUuid)?.uuidString.lowercased() : nil
    }

    /// The pointer we send for an uploaded attachment.
    public func pointer() -> Signalservice_AttachmentPointer {
        var p = Signalservice_AttachmentPointer()
        if let cdnKey { p.cdnKey = cdnKey }
        if let cdnNumber { p.cdnNumber = UInt32(cdnNumber) }
        p.contentType = contentType
        if let key, let k = Data(base64Encoded: key) { p.key = k }
        p.size = UInt32(size)
        if let digest, let d = Data(base64Encoded: digest) { p.digest = d }
        if let incrementalMac, let m = Data(base64Encoded: incrementalMac) { p.incrementalMac = m }
        if let chunkSize { p.chunkSize = UInt32(chunkSize) }
        if let uploadTimestamp { p.uploadTimestamp = uploadTimestamp }
        if let fileName { p.fileName = fileName }
        if let flags { p.flags = UInt32(flags) }
        if let width { p.width = UInt32(width) }
        if let height { p.height = UInt32(height) }
        if let caption { p.caption = caption }
        if let blurHash { p.blurHash = blurHash }
        if let clientUuid, let u = UUID(uuidString: clientUuid) { p.clientUuid = u.data }
        return p
    }

    public init(uploaded u: UploadedAttachment, contentType: String) {
        self.init(contentType: contentType, size: u.size)
        cdnKey = u.cdnKey
        cdnNumber = u.cdnNumber
        key = u.keys.base64EncodedString()
        digest = u.digest.base64EncodedString()
        plaintextHash = u.plaintextHash
        incrementalMac = u.incrementalMac?.base64EncodedString()
        chunkSize = u.chunkSize
        uploadTimestamp = u.uploadTimestamp
        clientUuid = UUID().uuidString.lowercased()
    }
}

extension UUID {
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

}

/// message_attachments rows.
public enum MessageAttachments {
    public struct Location: Sendable, Hashable, Codable {
        public var messageId: String
        public var type: MessageAttachmentType
        public var order: Int
        /// -1: the root message (not an edit-history entry).
        public var editHistoryIndex: Int = -1
    }

    static func bool(_ b: Bool?) -> Int? { b.map { $0 ? 1 : 0 } }

    public static func upsert(_ db: Database, _ loc: Location, conversationId: String, sentAt: Int64, receivedAt: Int64,
                              messageType: String, _ a: MessageAttachment) throws {
        try db.execute(sql: """
            INSERT INTO message_attachments (messageId, editHistoryIndex, attachmentType, orderInMessage, conversationId, sentAt, clientUuid,
                size, contentType, path, plaintextHash, localKey, caption, fileName, blurHash, height, width, digest, key, version,
                incrementalMac, incrementalMacChunkSize, transitCdnKey, transitCdnNumber, transitCdnUploadTimestamp,
                thumbnailPath, thumbnailSize, thumbnailContentType, thumbnailLocalKey, thumbnailVersion,
                screenshotPath, screenshotSize, screenshotContentType, screenshotLocalKey, screenshotVersion, duration,
                flags, error, wasTooBig, pending, messageType, receivedAt, receivedAtMs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (messageId, editHistoryIndex, attachmentType, orderInMessage) DO UPDATE SET
                clientUuid = excluded.clientUuid, size = excluded.size, contentType = excluded.contentType, path = excluded.path,
                plaintextHash = excluded.plaintextHash, localKey = excluded.localKey, caption = excluded.caption, fileName = excluded.fileName,
                blurHash = excluded.blurHash, height = excluded.height, width = excluded.width, digest = excluded.digest, key = excluded.key,
                version = excluded.version, incrementalMac = excluded.incrementalMac, incrementalMacChunkSize = excluded.incrementalMacChunkSize,
                transitCdnKey = excluded.transitCdnKey, transitCdnNumber = excluded.transitCdnNumber,
                transitCdnUploadTimestamp = excluded.transitCdnUploadTimestamp, thumbnailPath = excluded.thumbnailPath,
                thumbnailSize = excluded.thumbnailSize, thumbnailContentType = excluded.thumbnailContentType,
                thumbnailLocalKey = excluded.thumbnailLocalKey, thumbnailVersion = excluded.thumbnailVersion,
                screenshotPath = excluded.screenshotPath, screenshotSize = excluded.screenshotSize,
                screenshotContentType = excluded.screenshotContentType, screenshotLocalKey = excluded.screenshotLocalKey,
                screenshotVersion = excluded.screenshotVersion, duration = excluded.duration, flags = excluded.flags,
                error = excluded.error, wasTooBig = excluded.wasTooBig, pending = excluded.pending
            """, arguments: [
                loc.messageId, loc.editHistoryIndex, loc.type.rawValue, loc.order, conversationId, sentAt, a.clientUuid,
                a.size, a.contentType, a.path, a.plaintextHash, a.localKey, a.caption, a.fileName, a.blurHash, a.height, a.width, a.digest, a.key,
                a.version, a.incrementalMac, a.chunkSize, a.cdnKey, a.cdnNumber, a.uploadTimestamp.map { Int64($0) },
                a.thumbnail?.path, a.thumbnail?.size, a.thumbnail?.contentType, a.thumbnail?.localKey, a.thumbnail?.version,
                a.screenshot?.path, a.screenshot?.size, a.screenshot?.contentType, a.screenshot?.localKey, a.screenshot?.version, a.duration,
                a.flags, bool(a.error), bool(a.wasTooBig), bool(a.pending), messageType, receivedAt, receivedAt,
            ])
    }

    public static func fetch(_ db: Database, messageId: String) throws -> [(Location, MessageAttachment)] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM message_attachments WHERE messageId = ? ORDER BY editHistoryIndex, attachmentType, orderInMessage
            """, arguments: [messageId]).compactMap { row in
            guard let type = MessageAttachmentType(rawValue: row["attachmentType"]) else { return nil }
            return (Location(messageId: row["messageId"], type: type, order: row["orderInMessage"], editHistoryIndex: row["editHistoryIndex"]),
                    attachment(row))
        }
    }

    public static func fetch(_ db: Database, _ loc: Location) throws -> MessageAttachment? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM message_attachments WHERE messageId = ? AND editHistoryIndex = ? AND attachmentType = ? AND orderInMessage = ?
            """, arguments: [loc.messageId, loc.editHistoryIndex, loc.type.rawValue, loc.order]).map(attachment)
    }

    static func attachment(_ row: Row) -> MessageAttachment {
        var a = MessageAttachment(contentType: row["contentType"], size: row["size"])
        a.clientUuid = row["clientUuid"]; a.path = row["path"]; a.plaintextHash = row["plaintextHash"]; a.localKey = row["localKey"]
        a.caption = row["caption"]; a.fileName = row["fileName"]; a.blurHash = row["blurHash"]; a.height = row["height"]; a.width = row["width"]
        a.digest = row["digest"]; a.key = row["key"]; a.version = row["version"]; a.incrementalMac = row["incrementalMac"]
        a.chunkSize = row["incrementalMacChunkSize"]; a.cdnKey = row["transitCdnKey"]; a.cdnNumber = row["transitCdnNumber"]
        a.uploadTimestamp = (row["transitCdnUploadTimestamp"] as Int64?).map { UInt64($0) }; a.flags = row["flags"]
        a.error = (row["error"] as Int?).map { $0 != 0 }; a.wasTooBig = (row["wasTooBig"] as Int?).map { $0 != 0 }
        a.pending = (row["pending"] as Int?).map { $0 != 0 }
        if let path: String = row["thumbnailPath"], let key: String = row["thumbnailLocalKey"] {
            a.thumbnail = .init(path: path, localKey: key, size: row["thumbnailSize"] ?? 0, contentType: row["thumbnailContentType"] ?? "image/png",
                                version: row["thumbnailVersion"] ?? 2)
        }
        if let path: String = row["screenshotPath"], let key: String = row["screenshotLocalKey"] {
            a.screenshot = .init(path: path, localKey: key, size: row["screenshotSize"] ?? 0, contentType: row["screenshotContentType"] ?? "image/png",
                                 version: row["screenshotVersion"] ?? 2)
        }
        a.duration = row["duration"]
        return a
    }

    /// hasAttachments / hasFileAttachments / hasVisualMediaAttachments on the message row.
    public static func updateMessageFlags(_ db: Database, messageId: String) throws {
        let all = try fetch(db, messageId: messageId).filter { $0.0.type == .attachment && $0.0.editHistoryIndex == -1 }.map(\.1)
        let visual = all.contains { AttachmentPolicy.isImage($0.contentType) || AttachmentPolicy.isVideo($0.contentType) }
        let file = all.contains { !AttachmentPolicy.isImage($0.contentType) && !AttachmentPolicy.isVideo($0.contentType) && !AttachmentPolicy.isAudio($0.contentType) }
        try db.execute(sql: "UPDATE messages SET hasAttachments = ?, hasFileAttachments = ?, hasVisualMediaAttachments = ? WHERE id = ?",
                       arguments: [all.isEmpty ? 0 : 1, file ? 1 : 0, visual ? 1 : 0, messageId])
    }
}

/// Auto-download (ts/util/queueAttachmentDownloads.preload.ts) and size limits
/// (ts/types/AttachmentSize.std.ts).
public enum AttachmentPolicy {
    public static let mebibyte = 1024 * 1024
    /// `MAX_VOICE_MESSAGE_AUTO_DOWNLOAD_SIZE`: smaller voice notes download whatever the settings.
    public static let maxVoiceMessageAutoDownloadSize = 100 * 1024

    /// The `auto-download-attachment` item (DEFAULT_AUTO_DOWNLOAD_ATTACHMENT: all on).
    public struct AutoDownload: Codable, Equatable, Sendable {
        public var photos = true
        public var videos = true
        public var audio = true
        public var documents = true
        public init() {}
    }

    public static func autoDownload(_ db: Database) throws -> AutoDownload { try Items.get(db, "auto-download-attachment") ?? AutoDownload() }

    public static func isImage(_ t: String) -> Bool { t.hasPrefix("image/") }
    public static func isVideo(_ t: String) -> Bool { t.hasPrefix("video/") }
    public static func isAudio(_ t: String) -> Bool { t.hasPrefix("audio/") }

    /// `getMaximumIncomingAttachmentSize`: maxReceiveBytes, else 1.25 × maxBytes (100 MiB).
    public static func maximumIncomingSize(_ db: Database) throws -> Int {
        if let v = try RemoteConfig.int(db, "global.attachments.maxReceiveBytes") { return v }
        return Int(Double(try RemoteConfig.int(db, "global.attachments.maxBytes") ?? 100 * mebibyte) * 1.25)
    }

    /// `getMaximumAutoDownloadSize`
    public static func maximumAutoDownloadSize(_ db: Database) throws -> Int {
        try RemoteConfig.int(db, "global.attachments.maxAutoDownloadSizeBytes") ?? 200 * mebibyte
    }

    /// `getMaximumOutgoingAttachmentSize`
    public static func maximumOutgoingSize(_ db: Database) throws -> Int {
        try RemoteConfig.int(db, "global.attachments.maxBytes") ?? 100 * mebibyte
    }

    /// Whether a received attachment is queued without the user asking (`isAutoDownloadEnabled`
    /// with the disposition queueNormalAttachments picks).
    public static func shouldAutoDownload(_ a: MessageAttachment, type: MessageAttachmentType, settings: AutoDownload, maxAutoDownload: Int) -> Bool {
        switch type {
        case .longMessage, .sticker: return true
        case .quote, .preview, .contact: return settings.photos && a.size < maxAutoDownload
        case .attachment:
            let allowed: Bool
            if isVideo(a.contentType) { allowed = settings.videos }
            else if isImage(a.contentType) { allowed = settings.photos }
            else if isAudio(a.contentType) {
                if a.isVoiceMessage && a.size < maxVoiceMessageAutoDownloadSize { return true }
                allowed = settings.audio
            } else { allowed = settings.documents }
            return allowed && a.size < maxAutoDownload
        }
    }
}

// What sending and receiving attachments need: the at-rest store, the uploader and the media
// service (dimensions, blurhash, thumbnails — computed out of process).

import Foundation
import MediaXPCInterface

/// An attachment the user is sending.
public struct OutgoingAttachment: Sendable {
    public var data: Data
    public var contentType: String
    public var fileName: String?
    public var caption: String?
    public var flags: Int?

    public init(data: Data, contentType: String, fileName: String? = nil, caption: String? = nil, flags: Int? = nil) {
        self.data = data
        self.contentType = contentType
        self.fileName = fileName
        self.caption = caption
        self.flags = flags
    }
}

public enum OutgoingAttachmentError: Error, Equatable {
    case tooLarge(Int)
    /// An image or video whose metadata could not be removed (unparseable, or a type with no
    /// stripper): it is not sent rather than sent with its metadata.
    case metadataNotRemovable(String)
}

public struct AttachmentServices: Sendable {
    /// `MAX_DURATION_TO_REUSE_ATTACHMENT_CDN_POINTER` (ms).
    public static let reuseWindow: UInt64 = 3 * 86_400_000

    public let store: AttachmentStore
    public let uploader: AttachmentUploader
    public let media: (any MediaProcessing)?
    public let maxOutgoingSize: Int

    public init(store: AttachmentStore, uploader: AttachmentUploader, media: (any MediaProcessing)?, maxOutgoingSize: Int = 100 << 20) {
        self.store = store
        self.uploader = uploader
        self.media = media
        self.maxOutgoingSize = maxOutgoingSize
    }

    /// `canBeTranscoded`: images other than GIFs are scaled for sending.
    public static func canBeTranscoded(_ contentType: String) -> Bool { AttachmentPolicy.isImage(contentType) && contentType != "image/gif" }

    /// `autoScale` (at `level`; `highQuality` sends use level three), metadata removal for
    /// images and videos not re-encoded, then encrypts the result at rest and fills in image
    /// metadata (+ a 150 px thumbnail).
    public func prepare(_ original: OutgoingAttachment, level: MediaQualityLevel = .one, transcode: Bool = true) async throws -> MessageAttachment {
        var o = original
        var reencoded = false
        if transcode, Self.canBeTranscoded(o.contentType), let media,
           let scaled = try? await media.scaleForSending(o.data, contentType: o.contentType, level: level).validated(maxDimension: level.data.maxDimensions) {
            o.data = scaled.data
            o.contentType = scaled.contentType
            reencoded = true
        }
        // Metadata (Exif and GPS, XMP, IPTC, comments; a video's user data and times) never
        // leaves: a re-encoded image has none, everything else visual goes through the media
        // service's stripper first, and is refused if that fails.
        if !reencoded, AttachmentPolicy.isImage(o.contentType) || AttachmentPolicy.isVideo(o.contentType) {
            guard let media else { throw OutgoingAttachmentError.metadataNotRemovable("no media service") }
            do {
                o.data = try await media.stripMetadata(o.data, contentType: o.contentType).validatedStripped(original: o.data)
            } catch {
                throw OutgoingAttachmentError.metadataNotRemovable("\(o.contentType): \(error)")
            }
        }
        if o.contentType == "video/mp4" { o.data = VideoAttachments.sanitizeMP4(o.data).data }
        // handleVideoAttachment: file names are stripped from visual attachments.
        if AttachmentPolicy.isVideo(o.contentType) { o.fileName = nil }
        guard o.data.count <= maxOutgoingSize else { throw OutgoingAttachmentError.tooLarge(o.data.count) }
        var a = MessageAttachment(contentType: o.contentType, size: o.data.count)
        a.fileName = o.fileName
        a.caption = o.caption
        a.flags = o.flags
        a.clientUuid = UUID().uuidString.lowercased()
        let local = try store.storeLocally(o.data)
        a.path = local.path
        a.localKey = local.localKey.base64EncodedString()
        a.plaintextHash = local.plaintextHash
        a.version = 2
        if AttachmentPolicy.isImage(o.contentType), let media {
            if let info = try? await media.imageInfo(o.data).validated() {
                a.width = info.width
                a.height = info.height
                a.blurHash = info.blurHash
            }
            if let t = try? await media.thumbnail(o.data, size: MediaConstants.thumbnailSize).validated(size: MediaConstants.thumbnailSize) {
                let stored = try store.storeLocally(t.png)
                a.thumbnail = .init(path: stored.path, localKey: stored.localKey.base64EncodedString(), size: t.png.count, contentType: t.contentType,
                                    width: t.width, height: t.height)
            }
        }
        if AttachmentPolicy.isVideo(o.contentType), let media {
            try await VideoAttachments.addScreenshot(&a, data: o.data, media: media, store: store)
        }
        return a
    }

    /// Uploads a stored attachment; returns it with its transit pointer fields set.
    public func upload(_ a: MessageAttachment) async throws -> MessageAttachment {
        guard let plaintext = try store.plaintext(of: a) else { throw AttachmentDownloadError.missingPointer }
        let u = try await uploader.upload(plaintext, contentType: a.contentType)
        var out = a
        out.cdnKey = u.cdnKey
        out.cdnNumber = u.cdnNumber
        out.key = u.keys.base64EncodedString()
        out.digest = u.digest.base64EncodedString()
        out.incrementalMac = u.incrementalMac?.base64EncodedString()
        out.chunkSize = u.chunkSize
        out.uploadTimestamp = u.uploadTimestamp
        return out
    }
}

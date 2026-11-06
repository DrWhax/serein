// Outgoing and received video attachments.
//
// - Outgoing MP4s pass libsignal's Mp4Sanitizer (mp4san; the mobile clients' rule, Desktop
//   upstream sends the file as picked). It parses the whole box structure (so a malformed
//   file is not sent) and returns the presentation metadata as one contiguous block placed
//   before the media data ("faststart"); top-level extras (free, skip, meta, …) are dropped.
//   It keeps `moov` as it is, user data (`udta`: titles, location) included; `prepare` strips
//   that first in the media service (MetadataStrip). The output is the
//   sanitized metadata followed by the media-data span, or the input unchanged when it needed
//   no rewrite. Inputs it does not support (fragmented MP4, QuickTime without the isom
//   brand, discontiguous mdat) are sent as they are, as upstream Desktop does.
// - `handleVideoAttachment` / `captureDimensionsAndScreenshot`: the first frame as a PNG
//   screenshot (from the media service, rotated to display), with the video's display size and
//   duration.

import Foundation
import LibSignalClient
import MediaXPCInterface

public enum VideoAttachments {
    public enum SanitizeOutcome: Equatable, Sendable {
        case rewritten, unchanged, unsupported
    }

    /// The MP4 to send: sanitized, or the original when the sanitizer does not support it.
    public static func sanitizeMP4(_ data: Data) -> (data: Data, outcome: SanitizeOutcome) {
        let meta: SanitizedMetadata
        do { meta = try sanitizeMp4(input: SignalInputStreamAdapter(data), len: UInt64(data.count)) } catch { return (data, .unsupported) }
        guard let metadata = meta.metadata else { return (data, .unchanged) }
        let offset = meta.dataOffset, length = meta.dataLen
        guard offset <= UInt64(data.count), length <= UInt64(data.count) - offset else { return (data, .unsupported) }
        let start = data.startIndex + Int(offset)
        return (metadata + data[start ..< start + Int(length)], .rewritten)
    }

    /// Screenshot, display size and duration from the media service.
    static func addScreenshot(_ a: inout MessageAttachment, data: Data, media: any MediaProcessing, store: AttachmentStore) async throws {
        guard let poster = try? await media.posterFrame(data).validated() else { return }
        let stored = try store.storeLocally(poster.png)
        a.screenshot = .init(path: stored.path, localKey: stored.localKey.base64EncodedString(), size: poster.png.count, contentType: "image/png",
                             width: poster.width, height: poster.height)
        a.width = poster.width
        a.height = poster.height
        a.duration = poster.duration
    }
}

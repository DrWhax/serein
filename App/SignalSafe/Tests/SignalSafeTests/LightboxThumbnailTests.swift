// The Lightbox's thumbnail strip (a message with several photos): every item has its picture,
// the thumbnail stored at download (upstream's attachment.thumbnail) or, for an attachment
// stored without one, the timeline's decode; never the grey placeholder once either is there.

import Foundation
import SignalCore
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct LightboxThumbnailTests {
    static func pixel(_ v: UInt8) -> RGBAImage { RGBAImage(width: 1, height: 1, pixels: Data([v, v, v, 255]), scale: 1) }

    /// A stored thumbnail as the database row has it.
    static func storedThumbnail(_ path: String) -> SignalCore.MessageAttachment.LocalFile {
        try! JSONDecoder().decode(SignalCore.MessageAttachment.LocalFile.self, from: Data("""
            {"path": "\(path)", "localKey": "k", "size": 2, "contentType": "image/png", "width": 150, "height": 100, "version": 2}
            """.utf8))
    }

    @Test func twoPhotosHaveTheirThumbnails() {
        let session = SignalSession()
        var first = SignalCore.MessageAttachment(contentType: "image/jpeg", size: 4)
        first.path = "photo1"
        first.localKey = "key1"
        first.thumbnail = Self.storedThumbnail("thumb1")
        var second = SignalCore.MessageAttachment(contentType: "image/png", size: 4)
        second.path = "photo2"
        second.localKey = "key2"
        session.lightbox = .init(messageId: "message", attachments: [first, second], index: 0,
                                 authorTitle: nil, authorColor: "A200", timestamp: Date())
        // Decoded already: the first's stored thumbnail, the second's timeline image.
        session.images["thumb:thumb1"] = Self.pixel(10)
        session.images["photo2"] = Self.pixel(20)
        let items = session.lightboxItems(session.lightbox!)
        #expect(items.count == 2)
        #expect(items[0].thumbnail == Self.pixel(10))
        #expect(items[1].thumbnail == Self.pixel(20))
    }

    @Test func aThumbnailStillLoadingShowsTheTimelineImage() {
        let session = SignalSession()
        var photo = SignalCore.MessageAttachment(contentType: "image/jpeg", size: 4)
        photo.path = "photo"
        photo.localKey = "key"
        photo.thumbnail = Self.storedThumbnail("thumb")
        session.lightbox = .init(messageId: "message", attachments: [photo, photo], index: 1,
                                 authorTitle: nil, authorColor: "A200", timestamp: Date())
        session.images["photo"] = Self.pixel(30)
        #expect(session.lightboxItems(session.lightbox!).allSatisfy { $0.thumbnail == Self.pixel(30) })
    }
}

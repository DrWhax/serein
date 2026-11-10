import Foundation
import SignalCore
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct MediaRevocationTests {
    @Test func revocationClearsPixelsAndClosesTheViewer() {
        let session = SignalSession()
        var attachment = MessageAttachment(contentType: "image/png", size: 4)
        attachment.path = "old"
        attachment.localKey = "key"
        session.lightbox = .init(messageId: "message", attachments: [attachment], index: 0,
                                 authorTitle: nil, authorColor: "A200", timestamp: Date())
        session.images["large:old"] = RGBAImage(width: 1, height: 1, pixels: Data([0, 0, 0, 255]), scale: 1)
        session.imagePaths["large:old"] = "old"
        var available = MediaAvailability()
        available.messageIds = ["message"]
        available.paths = ["old"]
        available.messagePaths = ["message": ["old"]]
        session.applyMediaAvailability(available)
        #expect(session.lightbox != nil && session.images["large:old"] != nil)
        session.applyMediaAvailability(MediaAvailability())
        #expect(session.lightbox == nil && session.images["large:old"] == nil)
        #expect(session.imagePaths.isEmpty)
    }

    @Test func anotherMessageCannotKeepARevokedViewerOpen() {
        let session = SignalSession()
        var attachment = MessageAttachment(contentType: "image/png", size: 4)
        attachment.path = "shared"
        attachment.localKey = "key"
        session.lightbox = .init(messageId: "message", attachments: [attachment], index: 0,
                                 authorTitle: nil, authorColor: "A200", timestamp: Date())
        var state = MediaAvailability()
        state.messageIds = ["message", "other"]
        state.paths = ["shared", "remaining"]
        state.messagePaths = ["message": ["remaining"], "other": ["shared"]]
        session.activeAudioMessageId = "message"
        session.activeAudioPath = "shared"
        session.applyMediaAvailability(state)
        #expect(session.lightbox == nil)
        #expect(session.activeAudioMessageId == nil && session.activeAudioPath == nil)
    }
}

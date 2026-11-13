// A video in the timeline opens in the Lightbox, as a photo does (upstream Message
// showLightbox); nothing plays it in the bubble, its play button included. Only GIF-flagged
// videos play in place.

import Foundation
import SignalI18n
import Testing
@testable import SignalCore
@testable import SignalSafe
@testable import SignalUI

@MainActor @Suite struct VideoClickTests {
    @Test func aVideoOpensInTheLightbox() {
        let session = SignalSession()
        var video = SignalCore.MessageAttachment(contentType: "video/mp4", size: 4)
        video.path = "p"
        video.localKey = "k"
        var m = TimelineMessage(id: "m1", conversationId: "c1", direction: .incoming, body: "", sentAt: 0, receivedAt: 0, author: "a", status: nil,
                                hasAttachments: true, isDeleted: false, content: .video)
        m.attachments = [TimelineAttachment(location: .init(messageId: "m1", type: .attachment, order: 0), attachment: video)]
        let summary = ConversationSummary(id: "c1", kind: .private, title: "A", color: "A100", unreadCount: 0, isArchived: false,
                                          isPinned: false, isAccepted: true)
        let p = ConversationPane(session: session, conversation: summary, i18n: Localizer(locale: "en")).props(m, previous: nil, next: nil)
        #expect(p.playVideoInline == nil && p.inlineVideoPlayer == nil)
        #expect(p.showLightbox != nil)
    }
}

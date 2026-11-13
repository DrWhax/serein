// Sending view-once media (enqueueMessageForSend with isViewOnce, sendNormalMessage's
// eraseMessageContents 'view-once-sent'): against the mock server.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct ViewOnceSendTests {
    /// One photo goes out flagged view-once, without the draft's text; once sent, our copy is erased.
    @Test func aViewOncePhotoIsSentAndOurCopyErased() async throws {
        try await LinkedClient.with { c in
            let photo = OutgoingAttachment(data: AttachmentFlowTests.png(), contentType: "image/png", fileName: "a.png")
            let (id, _) = try await c.messenger.sendMessage("not sent", attachments: [photo], to: c.aliceAci, viewOnce: true)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(m["isViewOnce"] as? Bool == true)
            #expect((m["attachments"] as? [[String: Any]])?.count == 1)
            #expect((m["body"] as? String ?? "").isEmpty)
            var erased = false
            for _ in 0 ..< 100 {
                erased = try await c.database.pool.read { db in
                    let json = try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [id]) ?? "{}")
                    let files = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_attachments WHERE messageId = ?", arguments: [id]) ?? -1
                    return json["isErased"] as? Bool == true && json["isViewOnce"] as? Bool == true && files == 0
                }
                if erased { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(erased, "our copy is erased once the recipient has it")
        }
    }

    /// `isViewOnceEligible`: exactly one image or video, and not a reply.
    @Test func onlyOneImageOrVideoCanGoViewOnce() async throws {
        try await LinkedClient.with { c in
            let photo = OutgoingAttachment(data: AttachmentFlowTests.png(), contentType: "image/png", fileName: "a.png")
            let pdf = OutgoingAttachment(data: Data("%PDF".utf8), contentType: "application/pdf", fileName: "a.pdf")
            let t = try await c.send(["body": "hi"])
            let quoted = try await c.messageId(sentAt: t)
            for (attachments, quoting) in [([OutgoingAttachment](), nil), ([photo, photo], nil), ([pdf], nil), ([photo], Optional(quoted))] {
                await #expect(throws: ViewOnceSendError.ineligible) {
                    try await c.messenger.sendMessage("", attachments: attachments, quoting: quoting, to: c.aliceAci, viewOnce: true)
                }
            }
        }
    }
}

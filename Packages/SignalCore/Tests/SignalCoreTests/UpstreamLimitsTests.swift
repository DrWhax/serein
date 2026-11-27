// Limits upstream applies to what it sends and keeps of what it receives: draft attachments
// (preProcessAttachment), shown attachments (getValidMessageAttachments), incremental MACs,
// PollCreateSchema, body ranges (filterAndClean) and delete-for-me sync batches.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

@Suite struct UpstreamLimitTests {
    @Test func draftAttachmentRules() {
        typealias D = (contentType: String, fileName: String)
        let photo: D = ("image/jpeg", "a.jpg"), pdf: D = ("application/pdf", "a.pdf")
        #expect(AttachmentPolicy.draftRefusal(adding: "image/png", fileName: "b.png", to: [photo]) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "video/mp4", fileName: "b.mp4", to: [photo]) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "application/pdf", fileName: "a.pdf", to: []) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "application/pdf", fileName: "a.pdf", to: [photo]) == .cannotMixMultiAndNonMultiAttachments)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/png", fileName: "b.png", to: [pdf]) == .unsupportedMultiAttachment)
        // An SVG is a file, HEIC and a pasted TIFF bitmap are photos (sent as JPEG and PNG).
        #expect(AttachmentPolicy.draftRefusal(adding: "image/svg+xml", fileName: "a.svg", to: [photo]) == .cannotMixMultiAndNonMultiAttachments)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/heic", fileName: "b.heic", to: [photo]) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/tiff", fileName: "", to: [photo]) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/tiff", fileName: "scan.tiff", to: [photo]) == .cannotMixMultiAndNonMultiAttachments)
        let full = Array(repeating: photo, count: 32)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/png", fileName: "b.png", to: Array(full.prefix(31))) == nil)
        #expect(AttachmentPolicy.draftRefusal(adding: "image/png", fileName: "b.png", to: full) == .maxAttachments)
    }

    static func pointer(_ type: String, flags: UInt32 = 0, mac: Bool = false) -> Signalservice_AttachmentPointer {
        var p = Signalservice_AttachmentPointer()
        p.contentType = type
        p.flags = flags
        if mac {
            p.incrementalMac = Data([1, 2, 3])
            p.chunkSize = 4096
        }
        return p
    }

    @Test func validMessageAttachments() {
        let types = { (ps: [Signalservice_AttachmentPointer]) in AttachmentPolicy.validMessageAttachments(ps).map(\.contentType) }
        let jpg = Self.pointer("image/jpeg"), mp4 = Self.pointer("video/mp4"), pdf = Self.pointer("application/pdf")
        #expect(types([jpg, mp4, jpg]) == ["image/jpeg", "video/mp4", "image/jpeg"])
        #expect(types([jpg, pdf, jpg]) == ["image/jpeg"])
        #expect(types([pdf, jpg]) == ["application/pdf"])
        #expect(types([pdf]) == ["application/pdf"])
        // A GIF (a video flagged GIF) or a voice message leads alone.
        let gif = Self.pointer("video/mp4", flags: UInt32(Signalservice_AttachmentPointer.Flags.gif.rawValue))
        #expect(types([gif, jpg]) == ["video/mp4"])
        #expect(types([Self.pointer("audio/aac", flags: 1), jpg]) == ["audio/aac"])
    }

    @Test func incrementalMacsOnTheFirstTen() {
        let ps = [Self.pointer("image/jpeg")] + (0..<12).map { _ in Self.pointer("video/mp4", mac: true) }
        let out = AttachmentPolicy.limitingIncrementalMacs(ps)
        #expect(out.filter(\.hasIncrementalMac).count == 10 && out.filter(\.hasChunkSize).count == 10)
        #expect(out[1...10].allSatisfy(\.hasIncrementalMac) && !out[11].hasIncrementalMac && !out[12].hasChunkSize)
    }

    @Test func pollCreateSchema() {
        func poll(_ q: String, _ options: [String]) -> Bool {
            var p = Signalservice_DataMessage.PollCreate()
            p.question = q
            p.options = options
            return MessageModifiers.pollJSON(p) != nil
        }
        #expect(poll(String(repeating: "q", count: 200), ["a", "b"]))
        #expect(!poll(String(repeating: "q", count: 201), ["a", "b"]))
        #expect(poll("q", [String(repeating: "o", count: 100), "b"]))
        #expect(!poll("q", [String(repeating: "o", count: 101), "b"]))
        // 100 characters, but over 2 KiB.
        let families = String(repeating: "👩‍👩‍👧‍👦", count: 100)
        #expect(!poll(families, ["a", "b"]) && !poll("q", [families, "b"]))
        #expect(!poll("q", ["a"]) && !poll("q", Array(repeating: "o", count: 11)))
    }

    @Test func bodyRangesPerType() {
        var mention = Signalservice_BodyRange()
        mention.mentionAci = "6b8ae5a6-2a3e-4b2c-8b44-2b3f1d0c9a11"
        var bold = Signalservice_BodyRange()
        bold.style = .bold
        var italic = Signalservice_BodyRange()
        italic.style = .italic
        var none = Signalservice_BodyRange()
        none.style = .none
        let ranges = Array(repeating: mention, count: 300) + Array(repeating: bold, count: 260) + [italic, none]
        let out = MessageReceiver.bodyRangesJSON(ranges)
        #expect(out.filter { $0["mentionAci"] != nil }.count == 250)
        #expect(out.filter { $0["style"] as? Int == Signalservice_BodyRange.Style.bold.rawValue }.count == 250)
        #expect(out.filter { $0["style"] as? Int == Signalservice_BodyRange.Style.italic.rawValue }.count == 1)
        #expect(!out.contains { $0["style"] as? Int == 0 })
    }
}

@Suite(.serialized) struct UpstreamLimitFlowTests {
    /// 1,001 deletes go to our other devices as three sync messages of at most 500.
    @Test func deleteForMeSyncsInBatches() async throws {
        try await LinkedClient.with { c in
            let aci = c.aliceAci
            let ids = try await c.database.pool.write { db -> [String] in
                let conversationId = try MessageStore.privateConversation(db, serviceId: aci)
                let base = UInt64(MessageStore.now()) - 10_000
                return try (0..<1001).map { i in
                    try MessageStore.insert(db, .init(conversationId: conversationId, type: "incoming", body: "m\(i)", sentAt: base + UInt64(i), source: aci,
                                                      sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false, extra: [:]))
                }
            }
            try await c.messenger.deleteForMe(ids)
            var counts: [Int] = []
            for _ in 0..<3 {
                let sync = try await c.server.json("waitForSyncMessage", ["kind": "deleteForMe"])
                counts += (sync["deleteForMe"] as? [String: Any])?["messageCounts"] as? [Int] ?? []
            }
            #expect(counts.sorted() == [1, 500, 500])
        }
    }

    /// Of a message mixing a file with photos, only what upstream shows is kept.
    @Test func receivedMixedAttachmentsKeepWhatUpstreamShows() async throws {
        try await LinkedClient.with { c in
            try await c.acceptAlice()
            let image = AttachmentFlowTests.png()
            let pdf = Data("%PDF-1.4 test".utf8)
            // "p" a PNG, "f" a PDF.
            func send(_ kinds: String) async throws -> [String] {
                let ts = TestClock.next()
                let items: [[String: String]] = kinds.map { k in
                    k == "p" ? ["data": image.base64EncodedString(), "contentType": "image/png", "fileName": "a.png"]
                        : ["data": pdf.base64EncodedString(), "contentType": "application/pdf", "fileName": "a.pdf"]
                }
                _ = try await c.server.json("sendAttachments", ["from": "alice", "timestamp": ts, "body": "mixed", "items": items])
                _ = try await c.log.waitFor { if case .message(_, _, _, _, let t, _, _, _) = $0 { return t == ts } else { return false } }
                return try await c.database.pool.read { db in
                    let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(ts)])!
                    return try MessageAttachments.fetch(db, messageId: id).filter { $0.0.type == .attachment }.sorted { $0.0.order < $1.0.order }.map(\.1.contentType)
                }
            }
            #expect(try await send("pfp") == ["image/png"])
            #expect(try await send("fp") == ["application/pdf"])
            #expect(try await send("pp") == ["image/png", "image/png"])
        }
    }

    /// A message with an invalid poll is dropped, not kept without it.
    @Test func invalidPollDropsTheMessage() async throws {
        try await LinkedClient.with { c in
            let bad = TestClock.next()
            try await c.server.callJSON("sendDataMessage", ["from": "alice", "timestamp": bad, "message": [
                "pollCreate": ["question": String(repeating: "q", count: 201), "options": ["a", "b"], "allowMultiple": false]]])
            let good = try await c.send(["pollCreate": ["question": "Tea?", "options": ["yes", "no"], "allowMultiple": false]])
            let (badCount, goodPoll) = try await c.database.pool.read { db in
                (try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE sent_at = ?", arguments: [Int64(bad)]),
                 try String.fetchOne(db, sql: "SELECT json ->> '$.poll.question' FROM messages WHERE sent_at = ?", arguments: [Int64(good)]))
            }
            #expect(badCount == 0 && goodPoll == "Tea?")
        }
    }
}

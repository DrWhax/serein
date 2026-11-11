// Media revocation, the database side: `MediaAvailability.permits(path:messageId:)` (with and
// without a message) and `MediaAvailability.fetch` against the Lean model in Verification/Media,
// on random states of a real database: messages live, erased (deleted for everyone), expiring,
// or deleted, and attachment rows sharing files between messages.
//
// Run through Tools/verify-media.sh, or set SEREIN_MEDIA_ORACLE to the oracle executable.

import Foundation
import GRDB
import Testing
@testable import SignalCore

enum MediaOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Media").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_MEDIA_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

@Suite(.serialized, .enabled(if: MediaOracle.available, "build the oracle: Tools/verify-media.sh, or lake build in Verification/Media"))
struct MediaAvailabilityConformanceTests {
    @Test func randomStates() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let ourAci = UUID().uuidString.lowercased()
        let conversation = try await db.pool.write { try MessageStore.privateConversation($0, serviceId: UUID().uuidString.lowercased()) }
        var r = SplitMix(s: 1111)
        let count = ProcessInfo.processInfo.environment["SEREIN_MEDIA_CASES"].flatMap { Int($0) } ?? 2000
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<count {
            let now = r.below(4)
            // Four messages: live, erased, expiring at t (seconds), or deleted.
            let rows: [String] = (0..<4).map { _ in
                switch r.below(5) {
                case 0, 1: "L"
                case 2: "E"
                case 3: "X\(r.below(6))"
                default: "G"
                }
            }
            // Attachment rows: each (message, path) with some probability, files shared freely.
            var refs: [(Int, Int)] = []
            for m in 0..<4 { for p in 0..<3 where r.coin(3) { refs.append((m, p)) } }
            let rel = refs
            let ids = try await db.pool.write { db -> [String] in
                try db.execute(sql: "DELETE FROM message_attachments")
                try db.execute(sql: "DELETE FROM messages")
                let ids = try rows.map { _ in
                    try MessageStore.insert(db, .init(conversationId: conversation, type: "outgoing", body: "m", sentAt: 1, source: ourAci,
                                                      sourceDevice: 2, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                }
                for (k, (m, p)) in rel.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO message_attachments (messageId, editHistoryIndex, attachmentType, orderInMessage, conversationId, sentAt,
                                                         size, contentType, path)
                        VALUES (?, -1, 'attachment', ?, ?, 1, 1, 'image/png', ?)
                        """, arguments: [ids[m], k, conversation, "file-\(p)"])
                }
                for (m, row) in rows.enumerated() {
                    switch row.first {
                    case "E": try MessageStore.updateJSON(db, messageId: ids[m]) { $0["isErased"] = true }
                    case "X":
                        try db.execute(sql: "UPDATE messages SET expirationStartTimestamp = 0, expireTimer = ? WHERE id = ?",
                                       arguments: [Int(row.dropFirst())!, ids[m]])
                    case "G": try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [ids[m]])
                    default: break
                    }
                }
                return ids
            }
            let relCode = rel.isEmpty ? "-" : rel.map { "\($0.0):\($0.1)" }.joined(separator: ",")
            lines.append("\(rows.joined(separator: ",")) \(relCode) \(now)")
            let ms = Int64(now) * 1000
            let answer = try await db.pool.read { db -> String in
                var grid = ""
                for m in 0..<4 { for p in 0..<3 { grid += try MediaAvailability.permits(db, path: "file-\(p)", messageId: ids[m], now: ms) ? "1" : "0" } }
                var any = ""
                for p in 0..<3 { any += try MediaAvailability.permits(db, path: "file-\(p)", now: ms) ? "1" : "0" }
                let state = try MediaAvailability.fetch(db, now: ms)
                let refs = state.messagePaths.flatMap { id, paths in
                    paths.compactMap { path -> (Int, Int)? in
                        guard let m = ids.firstIndex(of: id), let p = Int(path.dropFirst(5)) else { return nil }
                        return (m, p)
                    }
                }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
                // The fetched message ids and paths must be exactly those of the references.
                let consistent = state.messageIds == Set(state.messagePaths.keys) && state.paths == Set(state.messagePaths.values.flatMap { $0 })
                return "\(grid) \(any) \(refs.isEmpty ? "-" : refs.map { "\($0.0):\($0.1)" }.joined(separator: ","))" + (consistent ? "" : " inconsistent")
            }
            swift.append(answer)
        }
        let model = try MediaOracle.call("db", lines)
        var reported = 0
        for (k, (m, s)) in zip(model, swift).enumerated() where m != s {
            reported += 1
            if reported <= 3 { Issue.record("disagree at step \(k) (\(lines[k]))\n  model \(m) | swift \(s)") }
        }
        #expect(model.count == lines.count && reported == 0, "\(reported) of \(lines.count) states disagree")
    }

    /// The save panel's export re-checks the message's own reference: exported while the message
    /// is live; refused once it is deleted for everyone, or expired, even though another message
    /// still references the same file.
    @Test func exportRechecksTheMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SignalDatabase(url: dir.appendingPathComponent("db.sqlite"), key: Data(repeating: 1, count: 32))
        let store = try AttachmentStore(root: dir.appendingPathComponent("files"))
        let stored = try store.storeLocally(Data("pixels".utf8))
        var a = MessageAttachment(contentType: "image/png", size: 6)
        a.path = stored.path
        a.localKey = stored.localKey.base64EncodedString()
        let (message, other) = try db.pool.write { db -> (String, String) in
            let conversation = try MessageStore.privateConversation(db, serviceId: UUID().uuidString.lowercased())
            let ids = try (0..<2).map { _ in
                try MessageStore.insert(db, .init(conversationId: conversation, type: "outgoing", body: "m", sentAt: 1, source: "me", sourceDevice: 1,
                                                  serverGuid: nil, serverTimestamp: nil, unidentified: false))
            }
            for (k, id) in ids.enumerated() {
                try db.execute(sql: """
                    INSERT INTO message_attachments (messageId, editHistoryIndex, attachmentType, orderInMessage, conversationId, sentAt, size,
                                                     contentType, path)
                    VALUES (?, -1, 'attachment', ?, ?, 1, 6, 'image/png', ?)
                    """, arguments: [id, k, conversation, stored.path])
            }
            return (ids[0], ids[1])
        }
        let out = dir.appendingPathComponent("saved.png")
        try MediaAvailability.export(a, of: message, to: out, database: db, store: store)
        #expect(try Data(contentsOf: out) == Data("pixels".utf8))
        try db.pool.write { try MessageStore.updateJSON($0, messageId: message) { $0["isErased"] = true } }
        #expect(throws: AttachmentStoreError.self) { try MediaAvailability.export(a, of: message, to: dir.appendingPathComponent("again.png"), database: db, store: store) }
        // The other message's reference still lets *it* export.
        try MediaAvailability.export(a, of: other, to: dir.appendingPathComponent("other.png"), database: db, store: store)
        try db.pool.write { db in
            try db.execute(sql: "UPDATE messages SET expirationStartTimestamp = 0, expireTimer = 1 WHERE id = ?", arguments: [other])
        }
        #expect(throws: AttachmentStoreError.self) { try MediaAvailability.export(a, of: other, to: dir.appendingPathComponent("late.png"), database: db, store: store) }
    }
}

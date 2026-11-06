// Plaintext export: frames through libsignal's JSON exporter into main.jsonl.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite(.serialized) struct PlaintextExportTests {
    @Test func exportsAccountRecipientsChatsAndMessages() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("hello from alice", withProfileKey: true)
            _ = try await c.messenger.sendText("hello back", to: c.aliceAci)
            try await c.eventually("sent") { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE type = 'outgoing'") == 1
            }
            try await c.database.pool.write { db in _ = try ChatFolderStore.ensureAllChats(db) }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-export-\(UUID())")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: target) }
            let result = try await PlaintextExport.export(database: c.database, account: c.account, attachments: c.attachmentStore, to: target,
                                                          includeMedia: true)
            #expect(result.exportDirectory.lastPathComponent.hasPrefix("signal-export-"))
            let lines = try String(contentsOf: result.exportDirectory.appendingPathComponent("main.jsonl"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(lines.count >= 6)
            let objects = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            #expect(objects.count == lines.count)
            #expect(objects.first?["version"] != nil)
            #expect(objects.contains { $0["account"] != nil })
            #expect(objects.contains { ($0["recipient"] as? [String: Any])?["contact"] != nil })
            #expect(objects.contains { $0["chat"] != nil })
            #expect(objects.contains { $0["chatFolder"] != nil })
            let texts = lines.filter { $0.contains("\"chatItem\"") }
            #expect(texts.contains { $0.contains("hello from alice") } && texts.contains { $0.contains("hello back") })
            let metadata = try String(contentsOf: result.exportDirectory.appendingPathComponent("metadata.json"), encoding: .utf8)
            #expect(metadata == "{\"version\":1}")
        }
    }

    @Test func varintMatchesProtobuf() {
        #expect(PlaintextExport.varint(1) == Data([1]))
        #expect(PlaintextExport.varint(300) == Data([0xAC, 0x02]))
    }
}

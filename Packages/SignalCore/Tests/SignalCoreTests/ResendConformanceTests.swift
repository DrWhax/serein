// Retry and resend authorization: production SignalCore against the Lean model in
// Verification/Resend — the send log (`SendLog.record`, `deleteRecipient`, pruning, `find`), the
// decision for a DecryptionErrorMessage (`SendLog.answer`: the device's own payload, a day, story
// lists, the retry limit) and `RetryLimiter`, on a real database, over random runs.
//
// Run through Tools/verify-resend.sh, or set SEREIN_RESEND_ORACLE to the oracle executable.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

enum ResendOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Resend").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_RESEND_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-resend-\(UUID().uuidString)")
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

@Suite(.serialized, .enabled(if: ResendOracle.available, "build the oracle: Tools/verify-resend.sh, or lake build in Verification/Resend"))
struct ResendConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_RESEND_CASES"].flatMap { Int($0) } ?? 3000 }
    static let hour: Int64 = 3_600_000
    static let base: Int64 = 1_000_000_000_000
    static func ms(_ hours: Int) -> Int64 { base + Int64(hours) * hour }

    /// The four contents: two messages, a story to lists, a group's story.
    static func contents() throws -> [Data] {
        var a = Signalservice_Content(), b = Signalservice_Content(), story = Signalservice_Content(), groupStory = Signalservice_Content()
        a.dataMessage.body = "a"
        b.dataMessage.body = "b"
        story.storyMessage.textAttachment.text = "s"
        groupStory.storyMessage.textAttachment.text = "g"
        groupStory.storyMessage.group.masterKey = Data(repeating: 1, count: 32)
        return try [a, b, story, groupStory].map { try $0.serializedBytes() }
    }

    /// Runs of sends, receipts, time, stories, list changes and retry requests: every request's
    /// answer against the oracle.
    @Test func randomRuns() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let contents = try Self.contents()
        let runs = max(1, Self.count / 10)
        let (lines, swift) = try await database.pool.write { db -> ([String], [String]) in
            var r = SplitMix(s: 73)
            var lines: [String] = [], swift: [String] = []
            for _ in 0..<runs {
                try db.execute(sql: "DELETE FROM sendLogPayloads")
                let accounts = (0..<4).map { _ in UUID().uuidString.lowercased() }
                let ourAci = UUID().uuidString.lowercased()
                let ourConversation = try MessageStore.privateConversation(db, serviceId: ourAci)
                let limiter = RetryLimiter()
                let start = r.below(10)
                var now = start
                // The model starts at hour 0: the run's start is a tick.
                var events: [String] = ["t \(start)"], answers: [String] = []
                // Two lists: (id, block, deleted, members).
                var lists: [(String, Bool, Bool, [Int])] = []
                for l in 0..<2 {
                    let members = (0..<4).filter { _ in r.coin() }
                    let block = r.coin(4)
                    let id = try StoryDistributionLists.create(db, name: "l\(l)", members: members.map { accounts[$0] })
                    if block { try StoryDistributionLists.update(db, listId: id, isBlockList: true) }
                    lists.append((id, block, false, members))
                    events.append("l \(l) \(block ? 1 : 0) 0 \(list(members))")
                }
                var storyTimes: Set<Int> = []
                for _ in 0..<40 {
                    let ts = 5 * r.below(8)
                    switch r.below(12) {
                    case 0, 1, 2:
                        let c = r.below(4), a = r.below(4)
                        let devices = (0..<3).filter { _ in r.coin() }
                        events.append("s \(ts) \(c) \(a) \(list(devices))")
                        try SendLog.record(db, timestamp: UInt64(Self.ms(ts)), contentHint: 0, proto: contents[c], urgent: true, recipient: accounts[a],
                                           devices: devices.map(UInt32.init), messageIds: [], now: Self.ms(now))
                    case 3:
                        let a = r.below(4), d = r.below(3)
                        events.append("d \(a) \(d) \(ts)")
                        try SendLog.deleteRecipient(db, recipient: accounts[a], deviceId: UInt32(d), timestamp: UInt64(Self.ms(ts)))
                    case 4:
                        let n = 2 * r.below(8)
                        now += n
                        events.append("t \(n)")
                    case 5:
                        guard !storyTimes.contains(ts) else { continue }
                        storyTimes.insert(ts)
                        let l = r.below(2)
                        var story = Signalservice_StoryMessage()
                        story.textAttachment.text = "s"
                        _ = try StoryStore.insert(db, .init(conversationId: ourConversation, source: ourAci, sourceDevice: 1, sentAt: UInt64(Self.ms(ts)),
                                                            serverTimestamp: nil, serverGuid: nil, story: story, outgoing: true, distributionListId: lists[l].0))
                        events.append("y \(ts) \(l)")
                    case 6:
                        let l = r.below(2)
                        guard !lists[l].2 else { continue }   // a deleted list stays deleted
                        if r.coin(6) {
                            try StoryDistributionLists.delete(db, listId: lists[l].0)
                            lists[l].2 = true
                            lists[l].3 = []
                        } else {
                            let members = (0..<4).filter { _ in r.coin() }
                            let block = r.coin(4)
                            try StoryDistributionLists.update(db, listId: lists[l].0, isBlockList: block, members: members.map { accounts[$0] })
                            lists[l].1 = block
                            lists[l].3 = members
                        }
                        events.append("l \(l) \(lists[l].1 ? 1 : 0) \(lists[l].2 ? 1 : 0) \(list(lists[l].3))")
                    default:
                        let a = r.below(4), d = r.below(3)
                        // Sometimes a burst of the same request (past the retry limit).
                        for _ in 0..<(r.coin(6) ? 7 : 1) {
                            events.append("q \(a) \(d) \(ts)")
                            let answered = limiter.count(requester: accounts[a], deviceId: UInt32(d), timestamp: UInt64(Self.ms(ts)))
                            switch try SendLog.answer(db, requester: accounts[a], deviceId: UInt32(d), timestamp: UInt64(Self.ms(ts)), answered: answered,
                                                      ourAci: ourAci, now: Self.ms(now)) {
                            case .resend(let p):
                                let hours = (Int64(p.timestamp) - Self.base) / Self.hour
                                answers.append("r:\(hours):\(contents.firstIndex(of: p.proto).map(String.init) ?? "?")")
                            case .nullMessage: answers.append("n")
                            case .nothing: answers.append("x")
                            }
                        }
                    }
                }
                lines.append("2 | " + events.joined(separator: " ; "))
                swift.append(answers.isEmpty ? "-" : answers.joined(separator: " "))
            }
            return (lines, swift)
        }
        compare(lines, model: try ResendOracle.call("run", lines), swift: swift)
    }
}

import Foundation
import MediaXPCInterface
@testable import MessageParsing
import SignalProtos
import Testing
import SwiftProtobuf
import Synchronization
import Dispatch

@Suite struct ParserSecurityTests {
    @Test func duplicateSingularFieldsFromTheHelperAreRejected() throws {
        let tree = ProtoTree(nodes: [
            .init(parent: 0, field: 0, kind: .message),
            .init(parent: 0, field: 1, kind: .bytes, bytes: Data("first".utf8)),
            .init(parent: 0, field: 1, kind: .bytes, bytes: Data("second".utf8)),
        ])
        #expect(throws: ProtoTree.TreeError.self) { try tree.validated().decode(Signalservice_DataMessage.self) }
    }
    @Test func duplicateSingularMessageMergesAreRejected() throws {
        // Content.dataMessage repeated as separate nodes can otherwise repeatedly copy/merge
        // a growing typed message in the app, outside the parser child's time budget.
        let tree = ProtoTree(nodes: [
            .init(parent: 0, field: 0, kind: .message),
            .init(parent: 0, field: 1, kind: .message),
            .init(parent: 1, field: 1, kind: .bytes, bytes: Data("first".utf8)),
            .init(parent: 0, field: 1, kind: .message),
            .init(parent: 3, field: 1, kind: .bytes, bytes: Data("second".utf8)),
        ])
        #expect(throws: ProtoTree.TreeError.self) { try tree.validated().decode(Signalservice_Content.self) }
    }
    @Test func rawDuplicateFieldsAreNormalizedByTheChild() throws {
        let bytes = Data([0x0A, 6, 0x0A, 1, 0x61, 0x0A, 1, 0x62])
        let result = try InProcessMessageParser().content(bytes, source: "peer")
        #expect(result.dataMessage.body == "b")
        var d = Signalservice_DataMessage()
        var range = Signalservice_BodyRange(); range.start = 1; range.length = 2; range.style = .bold
        d.bodyRanges = [range, range]
        #expect(try ProtoTree(d).validated().decode(Signalservice_DataMessage.self) == d)
    }

    @Test func budgetsApplyAcrossTrees() throws {
        let tree = ProtoTree(nodes: [.init(parent: 0, field: 0, kind: .message),
                                    .init(parent: 0, field: 1, kind: .bytes, bytes: Data([1, 2, 3, 4]))])
        try ProtoTree.validateBudget([tree, tree], maxNodes: 4, maxBytes: 8)
        #expect(throws: ProtoTree.TreeError.tooLarge) { try ProtoTree.validateBudget([tree, tree], maxNodes: 3, maxBytes: 8) }
        #expect(throws: ProtoTree.TreeError.tooLarge) { try ProtoTree.validateBudget([tree, tree], maxNodes: 4, maxBytes: 7) }
        #expect(throws: ProtoTree.TreeError.tooLarge) { try ProtoTree.validateBudget([tree], maxNodes: -1) }
    }

    /// Backup bytes as they are (the framing's limits without gzip).
    struct Passthrough: BackupInflater {
        var pending: [UInt8] = []
        var ended = false
        mutating func append(_ bytes: [UInt8]) throws { pending += bytes }
        mutating func read(atLeast: Int) throws -> [UInt8] { defer { pending = [] }; return pending }
        func finish() throws {}
    }

    /// The records a backup of `bytes` gives, read to its end.
    static func backupRecords(_ bytes: [UInt8]) throws -> Int {
        let parser = InProcessMessageParser(inflater: { Passthrough() })
        var records = try parser.backupRecords(Data(bytes), infoRead: false, source: "backup")
        var n = (records.info == nil ? 0 : 1) + records.frames.count
        while records.info != nil || !records.frames.isEmpty {
            records = try parser.backupRecords(Data(), infoRead: true, source: "backup")
            n += records.frames.count
        }
        try parser.backupEnd(source: "backup")
        return n
    }

    /// Records the stream of `bytes` gives with at most `maxRecords` in all.
    static func backupStream(_ bytes: [UInt8], maxRecords: Int) throws -> Int {
        var stream = BackupRecordStream(Passthrough(), maxRecords: maxRecords)
        var n = try stream.data(Data(bytes)).count
        while true {
            let more = try stream.data(Data()).count
            if more == 0 { break }
            n += more
        }
        _ = try stream.end()
        return n
    }

    @Test func backupFramingIsBounded() throws {
        var i = BackupProto_BackupInfo()
        i.version = 1
        var f = BackupProto_Frame()
        f.chat.id = 7
        let info: [UInt8] = try i.serializedBytes(), frame: [UInt8] = try f.serializedBytes()
        let record = [UInt8(info.count)] + info + [UInt8(frame.count)] + frame
        #expect(try Self.backupRecords(record + [UInt8(frame.count)] + frame) == 3)
        // Frames with nothing in them are skipped (backup.proto), but count towards the records.
        #expect(try Self.backupRecords(record + [0, 0, 0]) == 2)
        #expect(throws: MessageParserError.self) { _ = try Self.backupStream(record + [UInt8](repeating: 0, count: 10), maxRecords: 5) }
        // A record longer than allowed (refused before its bytes come), a length that does not
        // end, one cut short.
        #expect(throws: MessageParserError.self) { _ = try Self.backupRecords(record + [0x81, 0x80, 0x80, 0x20]) }
        #expect(throws: MessageParserError.self) { _ = try Self.backupRecords(record + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]) }
        #expect(throws: MessageParserError.self) { _ = try Self.backupRecords(record + [0x80]) }
        #expect(throws: MessageParserError.self) { _ = try Self.backupRecords(record + [5, 1, 2]) }
        // Nothing at all, and no backup open.
        #expect(throws: MessageParserError.self) { _ = try Self.backupRecords([]) }
        #expect(throws: MessageParserError.self) { try InProcessMessageParser(inflater: { Passthrough() }).backupEnd(source: "backup") }
        #expect(throws: MessageParserError.self) { _ = try InProcessMessageParser().backupRecords(Data(record), infoRead: false, source: "backup") }
    }

    private struct ManyTrees: StructuredMessageParser {
        let count: Int, bytes: Int
        func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree] {
            let tree = ProtoTree(nodes: [.init(parent: 0, field: 0, kind: .message), .init(parent: 0, field: 1, kind: .bytes, bytes: Data(count: self.bytes))])
            return Array(repeating: tree, count: count)
        }
    }
    @Test func aHelperCannotAnswerABackupPieceWithTooMuch() {
        #expect(throws: MessageParserError.self) { _ = try ManyTrees(count: MessageParserLimits.maxFrames + 1, bytes: 0).backupRecords(Data(), infoRead: true, source: "b") }
        #expect(throws: MessageParserError.self) { _ = try ManyTrees(count: 3, bytes: ProtoTree.Limits.maxBytes / 2).backupRecords(Data(), infoRead: true, source: "b") }
    }

    @Test func drainingPoolInvalidatesAnInFlightRefill() async throws {
        let count = Mutex(0), entered = Mutex(false), made = Mutex<[ParserChildProcess]>([])
        let release = DispatchSemaphore(value: 0)
        let pool = ParserChildPool {
            let n = count.withLock { $0 += 1; return $0 }
            if n == 2 {
                entered.withLock { $0 = true }
                guard release.wait(timeout: .now() + 10) == .success else { throw MessageParserError.unavailable("test gate timed out") }
            }
            let child = MessageParserTests.inProcessChild()
            made.withLock { $0.append(child) }
            return child
        }
        let active = try pool.take()
        defer { release.signal(); active.end(); pool.drain() }
        await MessageParserTests.wait { entered.withLock { $0 } }
        try #require(entered.withLock { $0 })
        pool.drain()
        release.signal()
        await MessageParserTests.wait { made.withLock { $0.count == 2 && !$0[1].isAlive } }
        #expect(made.withLock { $0.count == 2 && !$0[1].isAlive }, "retired refill left a child alive")
        let next = try pool.take()
        #expect(next.isAlive && next !== active)
        next.end()
    }

}

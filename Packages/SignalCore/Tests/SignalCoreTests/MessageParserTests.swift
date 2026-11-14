// The keyless parser (MessageParsing): what the service writes out reads back in the app as the
// same typed message, minus unknown fields; a tree that is not well formed, or a value of the
// wrong kind, is refused before or while it is read; the XPC parser keeps one source per
// service session, and the service gives each session a child process of its own.

import Foundation
import MediaXPCInterface
import MessageParsing
import SignalProtos
import SwiftProtobuf
import Synchronization
import Testing
import XPC

@Suite struct MessageParserTests {
    /// A Content using every kind of field Signal's messages have: unsigned varints, bools,
    /// enums, strings, bytes, nested and repeated messages, a fixed64 oneof (cdnID) and floats.
    static func richContent() -> Signalservice_Content {
        var d = Signalservice_DataMessage()
        d.body = "héllo \u{1F44B}"
        d.timestamp = 1_800_000_000_123
        d.expireTimer = 3600
        d.isViewOnce = true
        d.profileKey = Data(repeating: 7, count: 32)
        var a = Signalservice_AttachmentPointer()
        a.cdnID = UInt64.max - 5
        a.key = Data((0..<64).map { UInt8($0) })
        a.size = UInt32.max
        a.audioDurationSeconds = 12.75
        a.flags = 1
        a.contentType = "audio/aac"
        d.attachments = [a, a]
        var q = Signalservice_DataMessage.Quote()
        q.id = 42
        q.authorAci = "11111111-1111-4111-8111-111111111111"
        q.text = "quoted"
        q.type = .giftBadge
        d.quote = q
        var r = Signalservice_BodyRange()
        r.start = 0
        r.length = 5
        r.style = .bold
        d.bodyRanges = [r, r]
        var g = Signalservice_GroupContextV2()
        g.masterKey = Data(repeating: 1, count: 32)
        g.revision = 9
        d.groupV2 = g
        var c = Signalservice_Content()
        c.dataMessage = d
        var story = Signalservice_StoryMessage()
        var t = Signalservice_TextAttachment()
        t.text = "story"
        t.textStyle = .serif
        var gradient = Signalservice_TextAttachment.Gradient()
        gradient.positions = [0, 0.25, -1.5, .infinity]
        gradient.colors = [0xFF00_00FF, 0]
        t.gradient = gradient
        story.textAttachment = t
        c.storyMessage = story
        return c
    }

    @Test func messagesReadBackAsTheyWere() throws {
        let c = Self.richContent()
        let parsed = try InProcessMessageParser().content(try c.serializedData(), source: "content:a.1")
        #expect(parsed == c)
        // Sticker manifests too.
        var pack = Signalservice_StickerPack()
        pack.title = "Pack"
        pack.author = "Me"
        var s = Signalservice_StickerPack.Sticker()
        s.id = 3
        s.emoji = "🐸"
        pack.cover = s
        pack.stickers = [s, s]
        #expect(try InProcessMessageParser().stickerManifest(try pack.serializedData(), source: "sticker-pack:x") == pack)
    }

    @Test func unknownFieldsAreNotPassedOn() throws {
        var bytes = try Self.richContent().serializedData()
        // Field 999 (a varint) and field 1000 (bytes) at the top level.
        bytes.append(contentsOf: [0xB8, 0x3E, 0x05, 0xC2, 0x3E, 0x02, 0xAA, 0xBB])
        let parsed = try InProcessMessageParser().content(bytes, source: "content:a.1")
        #expect(parsed == Self.richContent() && parsed.unknownFields.data.isEmpty)
    }

    @Test func notAMessageIsMalformed() {
        #expect(throws: MessageParserError.self) { try InProcessMessageParser().content(Data([0x0A, 0x05, 0x01]), source: "s") }
        #expect(throws: MessageParserError.self) { try InProcessMessageParser().stickerManifest(Data([0xFF]), source: "s") }
    }

    // MARK: the tree's shape

    typealias Node = ProtoTree.Node

    static func tree(_ nodes: [Node]) -> ProtoTree { ProtoTree(nodes: [Node(parent: 0, field: 0, kind: .message)] + nodes) }

    @Test func malformedTreesAreRefused() {
        let bad: [(String, ProtoTree)] = [
            ("empty", ProtoTree(nodes: [])),
            ("root not a message", ProtoTree(nodes: [Node(parent: 0, field: 0, kind: .varint)])),
            ("root with a field number", ProtoTree(nodes: [Node(parent: 0, field: 1, kind: .message)])),
            ("parent after child", Self.tree([Node(parent: 2, field: 1, kind: .varint), Node(parent: 0, field: 2, kind: .message)])),
            ("parent itself", Self.tree([Node(parent: 1, field: 1, kind: .message)])),
            ("parent not a message", Self.tree([Node(parent: 0, field: 1, kind: .varint), Node(parent: 1, field: 1, kind: .varint)])),
            ("field 0", Self.tree([Node(parent: 0, field: 0, kind: .varint)])),
            ("reserved field", Self.tree([Node(parent: 0, field: 19_500, kind: .varint)])),
            ("field too large", Self.tree([Node(parent: 0, field: 1 << 29, kind: .varint)])),
            ("message with bits", Self.tree([Node(parent: 0, field: 1, kind: .message, bits: 1)])),
            ("varint with bytes", Self.tree([Node(parent: 0, field: 1, kind: .varint, bytes: Data([1]))])),
            ("fixed32 too wide", Self.tree([Node(parent: 0, field: 1, kind: .fixed32, bits: 1 << 32)])),
            ("bytes with bits", Self.tree([Node(parent: 0, field: 1, kind: .bytes, bits: 1)])),
        ]
        for (why, t) in bad {
            #expect(throws: ProtoTree.TreeError.self, "\(why)") { _ = try t.validated() }
        }
        // As deep as allowed, then one more.
        var nodes: [Node] = []
        for i in 0..<(ProtoTree.Limits.maxDepth - 1) { nodes.append(Node(parent: UInt32(i), field: 1, kind: .message)) }
        #expect(throws: Never.self) { _ = try Self.tree(nodes).validated() }
        nodes.append(Node(parent: UInt32(nodes.count), field: 1, kind: .message))
        nodes.append(Node(parent: UInt32(nodes.count), field: 1, kind: .varint))
        #expect(throws: ProtoTree.TreeError.tooDeep) { _ = try Self.tree(nodes).validated() }
    }

    /// Values of the wrong kind for their field, and strings that are not UTF-8, are refused;
    /// enum values the schema does not name are dropped.
    @Test func valuesMustFitTheirFields() throws {
        // DataMessage: body (1) is a string, expireTimer (5) a uint32.
        func data(_ nodes: [Node]) throws -> Signalservice_DataMessage { try Self.tree(nodes).validated().decode() }
        #expect(try data([Node(parent: 0, field: 1, kind: .bytes, bytes: Data("hi".utf8))]).body == "hi")
        #expect(throws: ProtoTree.TreeError.self) { try data([Node(parent: 0, field: 1, kind: .varint, bits: 1)]) }
        #expect(throws: ProtoTree.TreeError.self) { try data([Node(parent: 0, field: 1, kind: .bytes, bytes: Data([0xC3, 0x28]))]) }
        #expect(throws: ProtoTree.TreeError.self) { try data([Node(parent: 0, field: 5, kind: .bytes, bytes: Data([1]))]) }
        #expect(throws: ProtoTree.TreeError.self) { try data([Node(parent: 0, field: 5, kind: .message)]) }
        // BodyRange.style (4): BOLD is 1; 77 is no style.
        func range(_ v: UInt64) throws -> Signalservice_BodyRange { try Self.tree([Node(parent: 0, field: 4, kind: .varint, bits: v)]).validated().decode() }
        #expect(try range(1).style == .bold)
        #expect(try range(77).associatedValue == nil)
        // Fields the schema does not have are skipped, as protobuf skips them.
        #expect(try data([Node(parent: 0, field: 4_000, kind: .varint, bits: 1)]) == Signalservice_DataMessage())
    }

    // MARK: one source per session

    /// A handler that counts the sessions it has seen end.
    final class Counting: XPCMessageHandler {
        let inner = MessageParserXPCHandler()
        let ended = Atomic<Int>(0)
        var maxRequestBytes: Int { inner.maxRequestBytes }
        func reply(to request: XPCMessage) async throws -> XPCMessage { try await inner.reply(to: request) }
        func sessionEnded() { ended.add(1, ordering: .relaxed) }
    }

    static func wait(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func anotherSourceGetsAnotherSession() async throws {
        let handler = Counting()
        let listener = XPCServer.anonymous(requirement: nil, handler)
        defer { listener.cancel() }
        let parser = XPCMessageParser(channel: XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(10)))
        let bytes = try Self.richContent().serializedData()
        #expect(try parser.content(bytes, source: "content:alice.1") == Self.richContent())
        #expect(try parser.content(bytes, source: "content:alice.1") == Self.richContent())
        await Self.wait { handler.ended.load(ordering: .relaxed) > 0 }
        #expect(handler.ended.load(ordering: .relaxed) == 0)
        // Bob's message: Alice's session ends first.
        #expect(try parser.content(bytes, source: "content:bob.1") == Self.richContent())
        await Self.wait { handler.ended.load(ordering: .relaxed) == 1 }
        #expect(handler.ended.load(ordering: .relaxed) == 1)
        // The service's verdict on bad bytes is "malformed", not "unavailable".
        #expect(throws: MessageParserError.malformed("")) {
            do { _ = try parser.content(Data([0x0A, 0x05, 0x01]), source: "content:bob.1") } catch MessageParserError.malformed { throw MessageParserError.malformed("") }
        }
    }

    /// A service that cannot serve another session refuses it: the parser gives up as
    /// unavailable (the message stays cached and is tried again).
    @Test func aRefusedSessionIsUnavailable() async throws {
        let served = Counter()
        let listener = XPCServer.anonymous(requirement: nil) { () throws -> MessageParserXPCHandler in
            guard served.next() == 1 else { throw MediaProcessingError.unsupportedFormat }
            return MessageParserXPCHandler()
        }
        defer { listener.cancel() }
        let parser = XPCMessageParser(channel: XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(10)))
        let bytes = try Self.richContent().serializedData()
        #expect(try parser.content(bytes, source: "content:alice.1") == Self.richContent())
        do {
            _ = try parser.content(bytes, source: "content:bob.1")
            Issue.record("a second session was served")
        } catch MessageParserError.unavailable {}
    }

    // MARK: a child process per session (ParserChild.swift)

    final class Counter: Sendable {
        let n = Atomic<Int>(0)
        var value: Int { n.load(ordering: .relaxed) }
        @discardableResult func next() -> Int { n.add(1, ordering: .relaxed).newValue }
    }

    /// A child serving in this process over real pipes, on a thread of its own (the service's
    /// run SignalMessageParserChild). Ending it ends its input; it then closes its output, as a
    /// killed process's ends close (only ever when no request is in flight, in these tests).
    static func inProcessChild(_ started: Counter? = nil) -> ParserChildProcess {
        started?.next()
        let toChild = Pipe(), fromChild = Pipe()
        let running = Atomic<Bool>(true)
        let requests = toChild.fileHandleForWriting
        let child = ParserChildProcess(requests: requests, replies: fromChild.fileHandleForReading,
                                       isRunning: { running.load(ordering: .relaxed) },
                                       stop: { running.store(false, ordering: .relaxed); try? requests.close() })
        let input = toChild.fileHandleForReading, output = fromChild.fileHandleForWriting
        Thread.detachNewThread {
            ParserChild.serve(input: input, output: output, handler: MessageParserXPCHandler())
            running.store(false, ordering: .relaxed)
            try? output.close()
        }
        return child
    }

    static func request(_ kind: MessageParseKind, _ bytes: Data) throws -> XPCMessage {
        XPCMessage(payload: try Wire.encode(MessageParseRequest(kind: kind, bytes: bytes)))
    }

    /// Fail closed: a child (or the service) whose sandbox is not in force exits before it
    /// reads a request. This test process is not sandboxed, so the check must end it.
    @Test func aChildOutsideItsSandboxExits() async {
        await #expect(processExitsWith: .exitCode(78)) {
            ServiceSandbox.requireConfinement("SignalMessageParserChild")
        }
    }

    @Test func framesCrossThePipe() throws {
        let pipe = Pipe()
        // (Less than a pipe holds: nothing reads until all are written.)
        for frame in [Data("one".utf8), Data(), Data(repeating: 9, count: 30_000)] { try ParserPipe.write(frame, to: pipe.fileHandleForWriting) }
        try pipe.fileHandleForWriting.close()
        let r = pipe.fileHandleForReading
        #expect(try ParserPipe.read(r, maxBytes: 1 << 20) == Data("one".utf8))
        #expect(try ParserPipe.read(r, maxBytes: 1 << 20) == Data())
        #expect(try ParserPipe.read(r, maxBytes: 1 << 20)?.count == 30_000)
        #expect(try ParserPipe.read(r, maxBytes: 1 << 20) == nil)
        // Too long for the reader, and cut short.
        let big = Pipe()
        try ParserPipe.write(Data(count: 100), to: big.fileHandleForWriting)
        #expect(throws: ParserPipeError.tooLarge(100)) { try ParserPipe.read(big.fileHandleForReading, maxBytes: 99) }
        let cut = Pipe()
        try cut.fileHandleForWriting.write(contentsOf: Data([10, 0, 0, 0, 1, 2]))
        try cut.fileHandleForWriting.close()
        #expect(throws: ParserPipeError.truncated) { try ParserPipe.read(cut.fileHandleForReading, maxBytes: 99) }
    }

    @Test func aSessionRelaysToItsChild() async throws {
        let session = ParserChildSession(child: Self.inProcessChild(), start: { Self.inProcessChild() })
        defer { session.sessionEnded() }
        let reply = try await session.reply(to: Self.request(.content, try Self.richContent().serializedData()))
        let trees = try Wire.decode([ProtoTree].self, try reply.result(), maxBytes: 1 << 20)
        let content: Signalservice_Content = try trees[0].validated().decode()
        #expect(content == Self.richContent())
        // The child's verdict on bad bytes comes back as the reply's reason, as from the service before.
        let bad = try await session.reply(to: Self.request(.content, Data([0x0A, 0x05, 0x01])))
        #expect(bad.payload == nil && bad.error != nil)
    }

    @Test func aChildThatEndsIsReplacedForTheSameSource() async throws {
        let started = Counter()
        let first = Self.inProcessChild(started)
        let session = ParserChildSession(child: first, start: { Self.inProcessChild(started) })
        let bytes = try Self.richContent().serializedData()
        _ = try await session.reply(to: Self.request(.content, bytes)).result()
        // It crashed (or hung and was ended): the next request of this session gets a new child.
        first.end()
        _ = try await session.reply(to: Self.request(.content, bytes)).result()
        #expect(started.value == 2)
        // The session's end ends its child; nothing more is served on it.
        session.sessionEnded()
        await #expect(throws: MediaProcessingError.self) { try await session.reply(to: Self.request(.content, bytes)) }
        #expect(started.value == 2)
    }

    @Test func aChildEndedMidRequestFailsThatRequest() async throws {
        // A child that never answers: past the limit it is ended and the request fails.
        let toChild = Pipe(), fromChild = Pipe()
        let mute = ParserChildProcess(requests: toChild.fileHandleForWriting, replies: fromChild.fileHandleForReading, isRunning: { true },
                                      stop: { try? fromChild.fileHandleForWriting.close() })
        let session = ParserChildSession(child: mute, limit: .seconds(1), start: { Self.inProcessChild() })
        defer { session.sessionEnded() }
        let t0 = ContinuousClock.now
        await #expect(throws: MediaProcessingError.undecodable("the parser ended")) {
            try await session.reply(to: Self.request(.content, try Self.richContent().serializedData()))
        }
        #expect(ContinuousClock.now - t0 < .seconds(5))
        _ = toChild
    }

    @Test func thePoolHandsOutChildrenThatHaveParsedNothing() async throws {
        let made = Mutex<[ParserChildProcess]>([])
        let pool = ParserChildPool {
            let c = Self.inProcessChild()
            made.withLock { $0.append(c) }
            return c
        }
        let a = try pool.take()
        await Self.wait { made.withLock { $0.count } == 2 }   // a spare is started meanwhile
        let b = try pool.take()
        #expect(a !== b && made.withLock { $0[1] } === b)
        // A spare that died is not handed out: a new child is.
        await Self.wait { made.withLock { $0.count } == 3 }
        made.withLock { $0[2].end() }
        let c = try pool.take()
        #expect(c.isAlive && c !== made.withLock { $0[2] })
        for child in [a, b, c] { child.end() }
        pool.drain()
        await Self.wait { made.withLock { $0.allSatisfy { !$0.isAlive } } }
        #expect(made.withLock { $0.allSatisfy { !$0.isAlive } })
    }

    /// Over XPC, as the service runs it: each source's session has a child of its own, and the
    /// last source's child ends when the next source starts.
    @Test func eachSourceGetsItsOwnChild() async throws {
        let started = Counter()
        let children = Mutex<[ParserChildProcess]>([])
        let listener = XPCServer.anonymous(requirement: nil) { () throws -> ParserChildSession in
            let c = Self.inProcessChild(started)
            children.withLock { $0.append(c) }
            return ParserChildSession(child: c, start: { Self.inProcessChild(started) })
        }
        defer { listener.cancel() }
        let parser = XPCMessageParser(channel: XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(10)))
        let bytes = try Self.richContent().serializedData()
        #expect(try parser.content(bytes, source: "content:alice.1") == Self.richContent())
        #expect(try parser.content(bytes, source: "content:alice.1") == Self.richContent())
        #expect(started.value == 1)
        #expect(try parser.content(bytes, source: "content:bob.1") == Self.richContent())
        #expect(started.value == 2)
        await Self.wait { !(children.withLock { $0[0].isAlive }) }
        #expect(children.withLock { !$0[0].isAlive && $0[1].isAlive })
    }
}

/// The receive pipeline when the parser cannot be reached: the decrypted message is not lost
/// (nor answered with a retry request), it stays cached as it came and is delivered once the
/// parser answers again.
@Suite struct ParserOutageTests {
    /// Unavailable for its first `failures` requests, then the in-process parse.
    final class Flaky: StructuredMessageParser {
        let failures: Int
        let calls = Atomic<Int>(0)
        init(failures: Int) { self.failures = failures }
        func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree] {
            if calls.add(1, ordering: .relaxed).oldValue < failures { throw MessageParserError.unavailable("down") }
            return try InProcessMessageParser().trees(kind, bytes, source: source)
        }
    }

    @Test func messagesWaitForTheParser() async throws {
        let parser = Flaky(failures: 2)
        try await LinkedClient.with(parser: parser) { c in
            try await c.acceptAlice()
            let t = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "while the parser was down", "timestamp": t])
            _ = try await c.log.waitFor("kept") { if case .failed(_, let reason) = $0 { reason.contains("kept for later") } else { false } }
            // Delivered after the retries (1 s, then 2 s), with no retry request sent to alice.
            _ = try await c.log.waitFor(timeout: .seconds(15), "delivered") { if case .message(_, _, _, _, let ts, _, _, _) = $0 { ts == t } else { false } }
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM unprocessed") } == 0)
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM jobs WHERE data LIKE '%resendRequest%'") } == 0)
        }
    }
}

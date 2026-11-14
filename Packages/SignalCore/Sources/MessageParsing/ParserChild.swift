// One source's parser process. SignalMessageParser.xpc parses nothing itself: each session (one
// source of messages, MessageParser.swift) gets a child process of its own,
// SignalMessageParserChild, which inherits the service's Seatbelt rules and ends with the
// session. The service stays (launchd starts a service at most every ten seconds once one has
// exited early, so a process per source cannot be a service of its own), and keeps one spare
// child that has parsed nothing, so a new source never waits for a process to start.
//
// Requests and replies cross the child's stdin and stdout as frames; the service relays them
// without reading what is inside:
//
//   frame   := length:u32le bytes            length ≤ the reader's limit
//   request := the XPC request's payload (a MessageParseRequest, Wire.swift)
//   reply   := 0x00 payload | 0x01 reason (UTF-8, the error the child's handler threw)

import Foundation
import MediaXPCInterface
import Synchronization

public enum ParserPipeError: Error, Equatable {
    case tooLarge(Int)
    case truncated
    case badReply
    /// The stream itself failed (the other side is gone).
    case io(String)
}

public enum ParserPipe {
    public static func write(_ frame: Data, to h: FileHandle) throws(ParserPipeError) {
        guard let n = UInt32(exactly: frame.count) else { throw .tooLarge(frame.count) }
        var out = Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)])
        out.append(frame)
        do { try h.write(contentsOf: out) } catch { throw .io(String(describing: error)) }
    }

    /// The next frame; nil at the end of the stream. A frame longer than `maxBytes` is refused
    /// before anything is allocated for it.
    public static func read(_ h: FileHandle, maxBytes: Int) throws(ParserPipeError) -> Data? {
        guard let header = try exactly(4, h) else { return nil }
        let n = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard n <= maxBytes else { throw .tooLarge(n) }
        guard let body = try exactly(n, h) else { throw .truncated }
        return body
    }

    /// `n` bytes; nil if the stream ended before the first, an error if it ended within them.
    static func exactly(_ n: Int, _ h: FileHandle) throws(ParserPipeError) -> Data? {
        var out = Data()
        while out.count < n {
            let chunk: Data?
            do { chunk = try h.read(upToCount: n - out.count) } catch { throw .io(String(describing: error)) }
            guard let chunk, !chunk.isEmpty else {
                if out.isEmpty && n > 0 { return nil }
                throw .truncated
            }
            out.append(chunk)
        }
        return out
    }
}

/// The child's side: requests from `input` parsed by `handler` (on this thread: the child does
/// nothing else), replies to `output`, until the service closes the stream or it fails. No time
/// limit here: a child still parsing when its client gives up is ended with its session.
public enum ParserChild {
    public static func serve(input: FileHandle, output: FileHandle, handler: MessageParserXPCHandler) {
        // A reply to a service that has gone fails instead of raising SIGPIPE.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
        while let frame = try? ParserPipe.read(input, maxBytes: handler.maxRequestBytes) {
            var reply = Data([0])
            do {
                let request = try Wire.decode(MessageParseRequest.self, frame, maxBytes: MessageParserLimits.maxRequestBytes)
                reply.append(try Wire.encode(try handler.parse(request)))
            } catch {
                reply = Data([1])
                reply.append(Data(String(describing: error).utf8))
            }
            guard (try? ParserPipe.write(reply, to: output)) != nil else { return }
        }
    }
}

/// A running child: where its requests go and its replies come from, and how it is ended.
public final class ParserChildProcess: Sendable {
    public let requests: FileHandle
    public let replies: FileHandle
    let isRunning: @Sendable () -> Bool
    let stop: @Sendable () -> Void
    /// How it ended, for the error a failed request gets ("exit 78", "signal 9"; nil: unknown).
    let outcome: @Sendable () -> String?
    let ended = Atomic<Bool>(false)

    public init(requests: FileHandle, replies: FileHandle, isRunning: @escaping @Sendable () -> Bool, stop: @escaping @Sendable () -> Void,
                outcome: @escaping @Sendable () -> String? = { nil }) {
        self.requests = requests
        self.replies = replies
        self.isRunning = isRunning
        self.stop = stop
        self.outcome = outcome
    }

    /// Whether it can still take a request (not ended, and its process has not exited).
    public var isAlive: Bool { !ended.load(ordering: .relaxed) && isRunning() }

    /// Killed (once). The kernel closes the child's ends of the pipes, so a read in progress
    /// ends and a write fails; ours close when this is released. (Closing a FileHandle here
    /// could pull it from under a relay still using it, which Foundation answers with an
    /// exception.)
    public func end() {
        guard !ended.exchange(true, ordering: .relaxed) else { return }
        stop()
    }

    /// The child executable started with pipes for its stdin and stdout. It inherits the
    /// service's sandbox.
    public static func spawn(_ executable: URL) throws -> ParserChildProcess {
        let p = Process()
        p.executableURL = executable
        // Process opens the working directory for the child: its own folder, the one place
        // (with "/") the sandbox lets it read; the service's own working directory is not.
        p.currentDirectoryURL = executable.deletingLastPathComponent()
        // All three streams given: an XPC service has no standard streams of its own to pass
        // on (Process then fails with EBADF). What the child writes to stderr is read and
        // dropped until it exits: a closed pipe would kill it at its first write (SIGPIPE),
        // one nobody reads would stop it once full.
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        let drain = errors.fileHandleForReading
        Thread.detachNewThread {
            while let chunk = try? drain.read(upToCount: 1 << 16), !chunk.isEmpty {}
        }
        let pid = p.processIdentifier
        let holder = ProcessHolder()
        holder.process.withLock { $0 = p }
        // A write to a child that has died fails instead of raising SIGPIPE in the service.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return ParserChildProcess(requests: input.fileHandleForWriting, replies: output.fileHandleForReading,
                                  isRunning: { holder.process.withLock { $0?.isRunning ?? false } },
                                  stop: { _ = kill(pid, SIGKILL) },
                                  outcome: {
                                      holder.process.withLock { p in
                                          guard let p, !p.isRunning else { return nil }
                                          return (p.terminationReason == .exit ? "exit " : "signal ") + String(p.terminationStatus)
                                      }
                                  })
    }
}

/// Keeps the Process (which reaps the child) for as long as the child is used.
final class ProcessHolder: Sendable {
    let process = Mutex<Process?>(nil)
}

/// The spare: one child that has parsed nothing, started ahead so that a new session takes it
/// at once (and another is started for the next).
public final class ParserChildPool: Sendable {
    let spawn: @Sendable () throws -> ParserChildProcess
    struct State {
        var spare: ParserChildProcess?
        var generation: UInt64 = 0
        var refilling = false
    }
    let state = Mutex(State())

    public init(spawn: @escaping @Sendable () throws -> ParserChildProcess) { self.spawn = spawn }

    public func take() throws -> ParserChildProcess {
        let spare = state.withLock { s in let c = s.spare; s.spare = nil; return c }
        let child: ParserChildProcess
        if let spare, spare.isAlive { child = spare }
        else { spare?.end(); child = try spawn() }
        refill()
        return child
    }

    func refill() {
        let generation = state.withLock { s -> UInt64? in
            guard s.spare == nil, !s.refilling else { return nil }
            s.refilling = true
            return s.generation
        }
        guard let generation else { return }
        Task(name: "parser spare") { [self] in
            guard state.withLock({ $0.generation == generation }) else { return }
            let child = try? spawn()
            let extra = state.withLock { s -> ParserChildProcess? in
                // Drain can race both scheduling and process creation. Never install a spare
                // from a retired generation, or clear a newer refill's ownership.
                guard s.generation == generation else { return child }
                s.refilling = false
                if s.spare == nil { s.spare = child; return nil }
                return child
            }
            extra?.end()
        }
    }

    public func drain() {
        let spare = state.withLock { s in
            s.generation &+= 1
            s.refilling = false
            let c = s.spare
            s.spare = nil
            return c
        }
        spare?.end()
    }

}

/// The service's side of one session: its child (from the pool when it starts), each request
/// relayed to it and its reply relayed back, one at a time. A child that ends (it crashed on what
/// it was given, hung past `limit`, or replied with something that is not a reply) fails that
/// request, and the session's next request gets a new child (the same source). When the session
/// ends, so does its child.
///
/// The relay blocks on the child's pipes, so it runs on a serial queue of the session's own
/// (bridged with a continuation), never on the shared concurrency pool.
public final class ParserChildSession: XPCMessageHandler {
    let queue = DispatchSerialQueue(label: "org.signalsafe.parser.session")
    let child: Mutex<ParserChildProcess?>
    let ended = Atomic<Bool>(false)
    let start: @Sendable () throws -> ParserChildProcess
    let limit: Duration
    let onEnd: @Sendable () -> Void

    public init(child first: ParserChildProcess, limit: Duration = MessageParserLimits.budget(.backupData) + .seconds(5),
                start: @escaping @Sendable () throws -> ParserChildProcess, onEnd: @escaping @Sendable () -> Void = {}) {
        child = Mutex(first)
        self.start = start
        self.limit = limit
        self.onEnd = onEnd
    }

    public var maxRequestBytes: Int { MessageParserLimits.maxRequestBytes }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let payload = try request.requirePayload()
        return try await withCheckedThrowingContinuation { k in
            queue.async { k.resume(with: Result { try self.exchange(payload) }) }
        }
    }

    /// One request on the session's queue.
    func exchange(_ payload: Data) throws -> XPCMessage {
        guard !ended.load(ordering: .relaxed) else { throw MediaProcessingError.invalidResult }
        let c = try child.withLock { c -> ParserChildProcess in
            if let c, c.isAlive { return c }
            c?.end()
            let fresh = try start()
            c = fresh
            return fresh
        }
        // Past the limit the child is ended, which ends the read below.
        let timer = Task(name: "parser request limit") { [limit] in
            try await Task.sleep(for: limit)
            c.end()
        }
        defer { timer.cancel() }
        do throws(ParserPipeError) {
            try ParserPipe.write(payload, to: c.requests)
            guard let reply = try ParserPipe.read(c.replies, maxBytes: MessageParserLimits.maxReplyBytes + 1), let tag = reply.first, tag <= 1 else {
                throw .badReply
            }
            let body = Data(reply.dropFirst())
            return tag == 0 ? XPCMessage(payload: body) : XPCMessage(error: String(decoding: body, as: UTF8.self))
        } catch {
            // Give a child that died a moment to be reaped, so its end can be named.
            if !c.isRunning() { Thread.sleep(forTimeInterval: 0.05) }
            let how = c.outcome()
            c.end()
            throw MediaProcessingError.undecodable("the parser ended" + (how.map { " (\($0))" } ?? ""))
        }
    }

    public func sessionEnded() {
        guard !ended.exchange(true, ordering: .relaxed) else { return }
        child.withLock { c in
            c?.end()
            c = nil
        }
        onEnd()
    }
}

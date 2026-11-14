// The keyless structured-message parser: decrypted message content, contact-sync records,
// sticker manifests and backups are parsed by SignalMessageParser.xpc's child processes, with no
// keys, no database, no network and no files, and come back as ProtoTrees, which the app checks
// and reads back into typed messages without running a protobuf byte parser (TreeDecoder).
// Authorization and every database decision stay in the app.
//
// One process parses for one source only: the app ends the service's session whenever the
// source changes (another sender of decrypted content, another sticker pack, the contact sync),
// and each session gets a child process of its own, ended with it (ParserChild.swift). A message
// that took over a parser can then change only what that same source sends, which it could have
// sent anyway, and it cannot read or rewrite anyone else's.

import Foundation
import MediaXPCInterface
import SignalProtos
import SwiftProtobuf
import Synchronization

public enum MessageParseKind: String, Codable, Sendable {
    /// A decrypted, unpadded `Content`.
    case content
    /// A contact-sync blob: length-delimited `ContactDetails`, each followed by its avatar.
    case contactDetails
    /// A decrypted sticker pack manifest (`StickerPack`).
    case stickerManifest
    /// A link-and-sync backup, decrypted (still gzip): the service inflates it and keeps its
    /// frames for the session; the reply is its `BackupInfo` and how many runs of frames it has.
    case backupArchive
    /// A run of the session's backup frames, by index (4 bytes, big-endian): its `Frame`s.
    case backupFrames
}

public struct MessageParseRequest: Codable, Sendable {
    public var kind: MessageParseKind
    public var bytes: Data
    public init(kind: MessageParseKind, bytes: Data) {
        self.kind = kind
        self.bytes = bytes
    }
}

public enum MessageParserLimits {
    /// The largest input: a contact-sync blob (ContactSync's download limit).
    public static let maxInputBytes = 64 << 20
    /// The largest backup archive (gzip), and what it may inflate to.
    public static let maxArchiveBytes = 512 << 20
    public static let maxBackupBytes = 2 << 30
    /// Frames are handed out in runs of about this many bytes.
    public static let backupRunBytes = 1 << 20
    public static let maxRequestBytes = maxArchiveBytes + 4096
    public static func maxInput(_ kind: MessageParseKind) -> Int { kind == .backupArchive ? maxArchiveBytes : maxInputBytes }
    /// A reply: the trees take more room than the protobuf they came from.
    public static let maxReplyBytes = 256 << 20
    public static let maxContacts = 50_000
    /// Backup frames per request (the app sends runs of about a megabyte).
    public static let maxFrames = 100_000
    /// Parsing a message takes microseconds and a contact sync blob a second or so; one still
    /// being parsed after this ends the process, and counts as malformed (it made the parser hang).
    public static func budget(_ kind: MessageParseKind) -> Duration {
        switch kind {
        case .backupArchive: .seconds(60)
        case .contactDetails, .backupFrames: .seconds(20)
        case .content, .stickerManifest: .seconds(3)
        }
    }
}

public enum MessageParserError: Error, Equatable, CustomStringConvertible {
    /// Not a well-formed message of its kind (or the service said so).
    case malformed(String)
    /// The service could not be reached or did not answer: nothing is known about the message,
    /// which should be kept and parsed again later.
    case unavailable(String)

    public var description: String {
        switch self {
        case .malformed(let why): "malformed: \(why)"
        case .unavailable(let why): "message parser unavailable: \(why)"
        }
    }
}

// MARK: - the service's side

public final class MessageParserXPCHandler: XPCMessageHandler, Sendable {
    let gate: RequestGate
    /// gunzip for link-and-sync archives (the service's, CodecCore); nil: refused.
    let inflate: (@Sendable (Data) throws -> Data)?
    /// The session's backup: its inflated records and the runs of frames.
    struct Backup: Sendable { let bytes: Data; let runs: [[Range<Int>]] }
    let backup = Mutex<Backup?>(nil)

    public init(gate: RequestGate = RequestGate(), inflate: (@Sendable (Data) throws -> Data)? = nil) {
        self.gate = gate
        self.inflate = inflate
    }

    public var maxRequestBytes: Int { MessageParserLimits.maxRequestBytes }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let r = try Wire.decode(MessageParseRequest.self, try request.requirePayload(), maxBytes: MessageParserLimits.maxRequestBytes)
        return XPCMessage(payload: try await gate.run(budget: MessageParserLimits.budget(r.kind)) { try Wire.encode(try self.parse(r)) })
    }

    /// The trees for one request (what the service does).
    public func parse(_ r: MessageParseRequest) throws -> [ProtoTree] {
        switch r.kind {
        case .backupArchive: return try openBackup(r.bytes)
        case .backupFrames: return try backupRun(r.bytes)
        default: return try Self.parse(r)
        }
    }

    /// The stateless kinds.
    public static func parse(_ r: MessageParseRequest) throws -> [ProtoTree] {
        guard r.bytes.count <= MessageParserLimits.maxInputBytes else { throw MessageParserError.malformed("too large") }
        switch r.kind {
        case .content:
            return [try ProtoTree(Signalservice_Content(serializedBytes: r.bytes, options: options))]
        case .stickerManifest:
            return [try ProtoTree(Signalservice_StickerPack(serializedBytes: r.bytes, options: options))]
        case .contactDetails:
            return try ContactStream.records(r.bytes).map { try ProtoTree(Signalservice_ContactDetails(serializedBytes: $0, options: options)) }
        case .backupArchive, .backupFrames:
            throw MessageParserError.malformed("a backup needs a session")
        }
    }

    static var options: BinaryDecodingOptions {
        var o = BinaryDecodingOptions()
        o.messageDepthLimit = ProtoTree.Limits.maxDepth
        return o
    }

    func openBackup(_ gzip: Data) throws -> [ProtoTree] {
        guard let inflate else { throw MessageParserError.malformed("no backup support") }
        guard gzip.count <= MessageParserLimits.maxArchiveBytes else { throw MessageParserError.malformed("archive too large") }
        let plain: Data
        do { plain = try inflate(gzip) } catch { throw MessageParserError.malformed("gzip: \(error)") }
        let ranges = try BackupStream.ranges(plain)
        guard let first = ranges.first else { throw MessageParserError.malformed("empty backup") }
        let info = try BackupProto_BackupInfo(serializedBytes: plain[first], options: Self.options)
        var runs: [[Range<Int>]] = []
        var run: [Range<Int>] = [], size = 0
        for r in ranges.dropFirst() {
            run.append(r)
            size += r.count
            if size >= MessageParserLimits.backupRunBytes || run.count >= MessageParserLimits.maxFrames {
                runs.append(run)
                run = []
                size = 0
            }
        }
        if !run.isEmpty { runs.append(run) }
        backup.withLock { $0 = Backup(bytes: plain, runs: runs) }
        return [try ProtoTree(info), try ProtoTree(Google_Protobuf_UInt64Value(UInt64(runs.count)))]
    }

    func backupRun(_ index: Data) throws -> [ProtoTree] {
        guard index.count == 4 else { throw MessageParserError.malformed("run index") }
        let i = index.reduce(0) { $0 << 8 | Int($1) }
        guard let b = backup.withLock({ $0 }) else { throw MessageParserError.malformed("no backup open") }
        guard i < b.runs.count else { return [] }
        return try b.runs[i].map { try ProtoTree(BackupProto_Frame(serializedBytes: b.bytes[$0], options: Self.options)) }
    }
}

/// The contact-sync blob's framing (upstream ContactsParser): a varint length, that many bytes
/// of `ContactDetails`, then the avatar's `length` bytes (skipped).
public enum ContactStream {
    public static func records(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var offset = 0
        var out: [Data] = []
        while offset < bytes.count {
            guard out.count < MessageParserLimits.maxContacts else { throw MessageParserError.malformed("too many contacts") }
            let length = try varint32(bytes, &offset)
            guard length <= bytes.count - offset else { throw MessageParserError.malformed("truncated at \(offset)") }
            let record = Data(bytes[offset..<(offset + length)])
            offset += length
            // The avatar's length is in the record; the trees carry it, but the framing needs it now.
            let details = try Signalservice_ContactDetails(serializedBytes: record)
            if details.hasAvatar, details.avatar.hasLength {
                let avatar = Int(details.avatar.length)
                guard avatar <= bytes.count - offset else { throw MessageParserError.malformed("truncated at \(offset)") }
                offset += avatar
            }
            out.append(record)
        }
        return out
    }

    /// Protobuf base-128 varint, at most 5 bytes, value < 2^32.
    static func varint32(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        var value: UInt64 = 0
        for i in 0..<5 {
            guard offset < bytes.count else { throw MessageParserError.malformed("truncated at \(offset)") }
            let b = bytes[offset]
            offset += 1
            value |= UInt64(b & 0x7F) << (7 * UInt64(i))
            if b & 0x80 == 0 {
                guard value <= UInt64(UInt32.max) else { throw MessageParserError.malformed("varint too long at \(offset)") }
                return Int(value)
            }
        }
        throw MessageParserError.malformed("varint too long at \(offset)")
    }
}

/// A message backup's framing (protobuf encodeDelimited): a varint length, then the record.
public enum BackupStream {
    /// The records' byte ranges, in order.
    public static func ranges(_ data: Data) throws -> [Range<Int>] {
        let bytes = [UInt8](data)
        var offset = 0
        var out: [Range<Int>] = []
        while offset < bytes.count {
            let length = try ContactStream.varint32(bytes, &offset)
            guard length <= bytes.count - offset else { throw MessageParserError.malformed("truncated at \(offset)") }
            out.append((data.startIndex + offset)..<(data.startIndex + offset + length))
            offset += length
        }
        return out
    }
}

// MARK: - the app's side

/// What SignalCore asks of the parser. `source` names who the bytes come from (a sender's
/// service id and device, a sticker pack, the contact sync): the XPC parser never parses two
/// sources in one process.
public protocol StructuredMessageParser: Sendable {
    func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree]
}

extension StructuredMessageParser {
    public func content(_ bytes: Data, source: String) throws -> Signalservice_Content {
        try Self.one(try trees(.content, bytes, source: source))
    }

    public func stickerManifest(_ bytes: Data, source: String) throws -> Signalservice_StickerPack {
        try Self.one(try trees(.stickerManifest, bytes, source: source))
    }

    /// Opens a link-and-sync backup (decrypted gzip) in the parser: its BackupInfo and how
    /// many runs of frames `backupRun` hands out.
    public func backupArchive(_ gzip: Data, source: String) throws -> (info: BackupProto_BackupInfo, runs: Int) {
        let trees = try trees(.backupArchive, gzip, source: source)
        guard trees.count == 2 else { throw MessageParserError.malformed("expected info and count, got \(trees.count)") }
        let info: BackupProto_BackupInfo = try Self.decode(trees[0])
        let count: Google_Protobuf_UInt64Value = try Self.decode(trees[1])
        guard count.value <= UInt64(Int32.max) else { throw MessageParserError.malformed("run count") }
        return (info, Int(count.value))
    }

    /// Run `index` of the open backup's frames.
    public func backupRun(_ index: Int, source: String) throws -> [BackupProto_Frame] {
        guard index >= 0, index <= Int(Int32.max) else { throw MessageParserError.malformed("run index") }
        let bytes = Data([UInt8(index >> 24 & 0xFF), UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF)])
        let trees = try trees(.backupFrames, bytes, source: source)
        guard trees.count <= MessageParserLimits.maxFrames else { throw MessageParserError.malformed("too many frames") }
        return try trees.map { try Self.decode($0) }
    }

    public func contactDetails(_ stream: Data, source: String) throws -> [Signalservice_ContactDetails] {
        let trees = try trees(.contactDetails, stream, source: source)
        guard trees.count <= MessageParserLimits.maxContacts else { throw MessageParserError.malformed("too many contacts") }
        return try trees.map { try Self.decode($0) }
    }

    static func one<M: SwiftProtobuf.Message>(_ trees: [ProtoTree]) throws -> M {
        guard trees.count == 1 else { throw MessageParserError.malformed("expected one message, got \(trees.count)") }
        return try decode(trees[0])
    }

    static func decode<M: SwiftProtobuf.Message>(_ tree: ProtoTree) throws -> M {
        do { return try tree.validated().decode(M.self) } catch let e as ProtoTree.TreeError {
            throw MessageParserError.malformed("tree: \(e)")
        }
    }
}

/// The service's parse run in this process, its trees passed through the wire format and read
/// back as the app reads them (tests; and what the service runs).
public struct InProcessMessageParser: StructuredMessageParser {
    let handler: MessageParserXPCHandler
    /// `inflate`: gunzip for backups (as the service's); without it, backups are refused.
    public init(inflate: (@Sendable (Data) throws -> Data)? = nil) { handler = MessageParserXPCHandler(inflate: inflate) }
    public func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree] {
        let trees: [ProtoTree]
        do { trees = try handler.parse(MessageParseRequest(kind: kind, bytes: bytes)) } catch let e as MessageParserError {
            throw e
        } catch {
            throw MessageParserError.malformed(String(describing: error))
        }
        return try Wire.decode([ProtoTree].self, try Wire.encode(trees), maxBytes: MessageParserLimits.maxReplyBytes)
    }
}

/// SignalMessageParser.xpc: a session, and so a child process, per source.
public final class XPCMessageParser: StructuredMessageParser {
    public static let serviceName = "org.signalsafe.SignalMessageParser"

    let channel: XPCChannel
    /// The source the open session has parsed for.
    let source = Mutex<String?>(nil)
    /// Requests run one at a time, so a session never sees two sources.
    let serial = Mutex<Void>(())

    public init(channel: XPCChannel) { self.channel = channel }

    /// The bundled service, signed as XPCPeer says.
    public convenience init() {
        self.init(channel: XPCChannel(.service(Self.serviceName), peer: XPCPeer.requirement(.messageParser), timeout: MessageParserLimits.budget(.contactDetails) + .seconds(5)))
    }

    public func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree] {
        guard bytes.count <= MessageParserLimits.maxInput(kind) else { throw MessageParserError.malformed("too large") }
        let request = try Wire.encode(MessageParseRequest(kind: kind, bytes: bytes))
        return try serial.withLock { _ in
            // Another source: the child that parsed for the last one ends with its session.
            if self.source.withLock({ $0 }) != source {
                channel.reset()
                self.source.withLock { $0 = source }
            }
            var lastError = ""
            // A session the service refused, or one lost on the way (the service restarting): a
            // few tries, each on a session of its own.
            for attempt in 0..<5 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.01 * Double(1 << attempt)) }
                do {
                    let reply = try channel.sendSync(request, timeout: MessageParserLimits.budget(kind) + .seconds(1), maxReply: MessageParserLimits.maxReplyBytes)
                    do { return try Wire.decode([ProtoTree].self, reply, maxBytes: MessageParserLimits.maxReplyBytes) } catch {
                        throw MessageParserError.malformed("reply: \(error)")
                    }
                } catch let e as MediaProcessingError {
                    // The service's own answer: the bytes are not a message of this kind.
                    throw MessageParserError.malformed(String(describing: e))
                } catch let e as MessageParserError {
                    throw e
                } catch XPCServiceError.timedOut {
                    // Still parsing past its budget: these bytes made it hang. Not again.
                    channel.reset()
                    self.source.withLock { $0 = nil }
                    throw MessageParserError.malformed("the parser timed out")
                } catch {
                    lastError = String(describing: error)
                    channel.reset()
                }
            }
            self.source.withLock { $0 = nil }
            throw MessageParserError.unavailable(lastError)
        }
    }
}

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
    /// The next piece of a link-and-sync backup, decrypted (still gzip; empty: read on): the
    /// session's parser inflates as it goes and replies with the records completed so far, about
    /// a megabyte of them at most, its `BackupInfo` first and then `Frame`s (BackupStreaming.swift).
    case backupData
    /// The backup's last piece was sent: the gzip member and the last record must be complete.
    case backupEnd
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
    /// Backup records are handed out in runs of about this many bytes.
    public static let backupRunBytes = 1 << 20
    public static let maxRequestBytes = maxInputBytes + 4096
    public static func maxInput(_ kind: MessageParseKind) -> Int { kind == .backupData ? maxBackupPieceBytes : maxInputBytes }
    /// A reply: the trees take more room than the protobuf they came from.
    public static let maxReplyBytes = 256 << 20
    public static let maxContacts = 50_000
    /// Backup frames per reply (the parser hands out runs of about a megabyte).
    public static let maxFrames = 100_000
    /// Records in a whole backup: bounds the work a stream of tiny records can make (records of
    /// no bytes are refused outright). A long history has millions of messages; this is far above.
    public static let maxBackupRecords = 1 << 26
    /// The largest record of a backup.
    public static let maxBackupRecordBytes = maxInputBytes
    /// Parsing a message takes microseconds and a contact sync blob a second or so; one still
    /// being parsed after this ends the process, and counts as malformed (it made the parser hang).
    public static func budget(_ kind: MessageParseKind) -> Duration {
        switch kind {
        case .contactDetails, .backupData, .backupEnd: .seconds(20)
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

/// Same wire shape as [ProtoTree], with aggregate limits enforced during decoding.
struct MessageParseReply: Decodable {
    let trees: [ProtoTree]
    init(from decoder: any Swift.Decoder) throws {
        var input = try decoder.unkeyedContainer()
        var trees: [ProtoTree] = []
        var budget = ProtoTree.Budget()
        while !input.isAtEnd {
            guard trees.count < MessageParserLimits.maxFrames else { throw ProtoTree.TreeError.tooLarge }
            let tree = try input.decode(ProtoTree.self)
            try budget.consume(tree)
            trees.append(tree)
        }
        self.trees = trees
    }
}

// MARK: - the service's side

public final class MessageParserXPCHandler: XPCMessageHandler, Sendable {
    let gate: RequestGate
    /// Streaming gunzip for link-and-sync backups (the child's, CodecCore); nil: refused.
    let inflater: (@Sendable () -> any BackupInflater)?
    /// The session's backup, as far as it has come.
    let backup = Mutex<BackupRecordStream?>(nil)

    public init(gate: RequestGate = RequestGate(), inflater: (@Sendable () -> any BackupInflater)? = nil) {
        self.gate = gate
        self.inflater = inflater
    }

    public var maxRequestBytes: Int { MessageParserLimits.maxRequestBytes }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        let r = try Wire.decode(MessageParseRequest.self, try request.requirePayload(), maxBytes: MessageParserLimits.maxRequestBytes)
        return XPCMessage(payload: try await gate.run(budget: MessageParserLimits.budget(r.kind)) { try Wire.encode(try self.parse(r)) })
    }

    /// The trees for one request (what the service does).
    public func parse(_ r: MessageParseRequest) throws -> [ProtoTree] {
        switch r.kind {
        case .backupData:
            guard let inflater else { throw MessageParserError.malformed("no backup support") }
            return try backup.withLock { b in
                if b == nil { b = BackupRecordStream(inflater()) }
                return try b!.data(r.bytes)
            }
        case .backupEnd:
            return try backup.withLock { b in
                guard b != nil else { throw MessageParserError.malformed("no backup open") }
                return try b!.end()
            }
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
            return try recordTrees(ContactStream.records(r.bytes), as: Signalservice_ContactDetails.self)
        case .backupData, .backupEnd:
            throw MessageParserError.malformed("a backup needs a session")
        }
    }

    static func recordTrees<M: SwiftProtobuf.Message>(_ records: [Data], as type: M.Type) throws -> [ProtoTree] {
        var out: [ProtoTree] = []
        var budget = ProtoTree.Budget()
        for record in records {
            let tree = try ProtoTree(M(serializedBytes: record, options: options))
            try budget.consume(tree)
            out.append(tree)
        }
        return out
    }

    static var options: BinaryDecodingOptions {
        var o = BinaryDecodingOptions()
        o.messageDepthLimit = ProtoTree.Limits.maxDepth
        return o
    }
}

/// The contact-sync blob's framing (upstream ContactsParser): a varint length, that many bytes
/// of `ContactDetails`, then the avatar's `length` bytes (skipped).
public enum ContactStream {
    public static func records(_ data: Data) throws -> [Data] {
        guard data.count <= MessageParserLimits.maxInputBytes else { throw MessageParserError.malformed("contacts too large") }
        var offset = 0
        var out: [Data] = []
        while offset < data.count {
            guard out.count < MessageParserLimits.maxContacts else { throw MessageParserError.malformed("too many contacts") }
            let length = try varint32(data, &offset)
            guard length <= data.count - offset else { throw MessageParserError.malformed("truncated at \(offset)") }
            let record = data[(data.startIndex + offset)..<(data.startIndex + offset + length)]
            offset += length
            // The avatar's length is in the record; the trees carry it, but the framing needs it now.
            let details = try Signalservice_ContactDetails(serializedBytes: record, options: MessageParserXPCHandler.options)
            if details.hasAvatar, details.avatar.hasLength {
                let avatar = Int(details.avatar.length)
                guard avatar <= data.count - offset else { throw MessageParserError.malformed("truncated at \(offset)") }
                offset += avatar
            }
            out.append(record)
        }
        return out
    }

    /// Protobuf base-128 varint, at most 5 bytes, value < 2^32.
    static func varint32<C: RandomAccessCollection>(_ bytes: C, _ offset: inout Int) throws -> Int where C.Element == UInt8, C.Index == Int {
        var value: UInt64 = 0
        for i in 0..<5 {
            guard offset < bytes.count else { throw MessageParserError.malformed("truncated at \(offset)") }
            let b = bytes[bytes.startIndex + offset]
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

    public func contactDetails(_ stream: Data, source: String) throws -> [Signalservice_ContactDetails] {
        let trees = try trees(.contactDetails, stream, source: source)
        guard trees.count <= MessageParserLimits.maxContacts else { throw MessageParserError.malformed("too many contacts") }
        try ProtoTree.validateBudget(trees)
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
    /// `inflater`: streaming gunzip for backups (as the child's); without it, backups are refused.
    public init(inflater: (@Sendable () -> any BackupInflater)? = nil) { handler = MessageParserXPCHandler(inflater: inflater) }
    public func trees(_ kind: MessageParseKind, _ bytes: Data, source: String) throws -> [ProtoTree] {
        let trees: [ProtoTree]
        do { trees = try handler.parse(MessageParseRequest(kind: kind, bytes: bytes)) } catch let e as MessageParserError {
            throw e
        } catch {
            throw MessageParserError.malformed(String(describing: error))
        }
        return try Wire.decode(MessageParseReply.self, try Wire.encode(trees), maxBytes: MessageParserLimits.maxReplyBytes).trees
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
                    do { return try Wire.decode(MessageParseReply.self, reply, maxBytes: MessageParserLimits.maxReplyBytes).trees } catch {
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

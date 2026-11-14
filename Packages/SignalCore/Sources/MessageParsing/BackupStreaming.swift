// Link-and-sync backups, streamed. The app checks its archive file's MAC, then decrypts it
// piece by piece and hands each piece of gzip to the parser (`.backupData`). The parser inflates
// as it goes (an inflater the child gives it: MessageParsing links no codec code) and answers
// with the records the input so far completes, about a megabyte of them at most per answer:
// the backup's BackupInfo first, then its Frames. An empty answer asks for the next piece.
// `.backupEnd` then checks that the gzip member, with its CRC and size, and the last record are
// complete. Neither side holds the backup whole: the parser keeps the inflater's window, the
// input of one Deflate block and the records not yet answered (one record at most beyond them).

import Foundation
import SignalProtos
import SwiftProtobuf

/// Streaming gunzip (the child's, CodecCore's GzipStream).
public protocol BackupInflater: Sendable {
    /// More of the gzip stream.
    mutating func append(_ bytes: [UInt8]) throws
    /// Output decoded from the input so far: at least `atLeast` bytes unless that runs out;
    /// empty when more input is needed (or the member is complete).
    mutating func read(atLeast: Int) throws -> [UInt8]
    /// The input has ended: the member must be complete, with nothing after it.
    func finish() throws
}

extension MessageParserLimits {
    /// The largest piece of a backup per request (the app sends a megabyte).
    public static let maxBackupPieceBytes = 4 << 20
}

/// One session's backup in the parser.
struct BackupRecordStream: Sendable {
    var inflater: any BackupInflater
    /// Inflated bytes not yet answered: `plain[start...]`.
    var plain: [UInt8] = []
    var start = 0
    var records = 0
    var ended = false
    let maxRecords: Int

    init(_ inflater: any BackupInflater, maxRecords: Int = MessageParserLimits.maxBackupRecords) {
        self.inflater = inflater
        self.maxRecords = maxRecords
    }

    /// `.backupData`: the records `piece` (possibly empty) completes, up to a run's worth.
    mutating func data(_ piece: Data) throws -> [ProtoTree] {
        guard !ended else { throw MessageParserError.malformed("the backup has ended") }
        guard piece.count <= MessageParserLimits.maxBackupPieceBytes else { throw MessageParserError.malformed("piece too large") }
        do { try inflater.append([UInt8](piece)) } catch { throw MessageParserError.malformed("gzip: \(error)") }
        var trees: [ProtoTree] = []
        // A reply's trees share one budget (MessageParseReply holds the app to the same).
        var budget = ProtoTree.Budget()
        var size = 0
        while size < MessageParserLimits.backupRunBytes, trees.count < MessageParserLimits.maxFrames {
            if let record = try nextRecord() {
                // A frame with nothing in it is skipped (backup.proto: "importers should skip
                // this frame"); it still counts towards the backup's records.
                if record.isEmpty, records > 0 {
                    records += 1
                    continue
                }
                let t = try tree(record)
                do { try budget.consume(t) } catch { throw MessageParserError.malformed("backup reply too large") }
                trees.append(t)
                size += record.count
                continue
            }
            let more: [UInt8]
            do { more = try inflater.read(atLeast: MessageParserLimits.backupRunBytes) } catch { throw MessageParserError.malformed("gzip: \(error)") }
            if more.isEmpty { break }
            if start > 0 {
                plain.removeFirst(start)
                start = 0
            }
            plain += more
        }
        return trees
    }

    /// `.backupEnd`: everything was read, and it was all there.
    mutating func end() throws -> [ProtoTree] {
        guard !ended else { throw MessageParserError.malformed("the backup has ended") }
        do { try inflater.finish() } catch { throw MessageParserError.malformed("gzip: \(error)") }
        guard start == plain.count else { throw MessageParserError.malformed("the backup ends inside a record") }
        guard records > 0 else { throw MessageParserError.malformed("empty backup") }
        ended = true
        return []
    }

    /// The next whole record (protobuf encodeDelimited), nil until it has all come.
    mutating func nextRecord() throws -> ArraySlice<UInt8>? {
        var length = 0
        var offset = start
        for i in 0..<5 {
            guard offset < plain.count else { return nil }
            let b = plain[offset]
            offset += 1
            length |= Int(b & 0x7F) << (7 * i)
            if b & 0x80 == 0 { break }
            guard i < 4 else { throw MessageParserError.malformed("record length too long") }
        }
        guard length <= MessageParserLimits.maxBackupRecordBytes else { throw MessageParserError.malformed("backup record too large") }
        guard records < maxRecords else { throw MessageParserError.malformed("too many backup records") }
        guard plain.count - offset >= length else { return nil }
        start = offset + length
        return plain[offset..<start]
    }

    mutating func tree(_ record: ArraySlice<UInt8>) throws -> ProtoTree {
        defer { records += 1 }
        let bytes = Data(record)
        if records == 0 {
            return try ProtoTree(BackupProto_BackupInfo(serializedBytes: bytes, options: MessageParserXPCHandler.options))
        }
        return try ProtoTree(BackupProto_Frame(serializedBytes: bytes, options: MessageParserXPCHandler.options))
    }
}

// MARK: - the app's side

/// What one piece of a backup gave: its BackupInfo (in the first answer that has records) and
/// frames.
public struct BackupRecords: Sendable {
    public var info: BackupProto_BackupInfo?
    public var frames: [BackupProto_Frame]
}

extension StructuredMessageParser {
    /// Hands the parser the next piece of a link-and-sync backup (decrypted gzip; empty: read on)
    /// and takes the records it completes. `infoRead`: the BackupInfo came in an earlier answer.
    /// No records: the parser needs the next piece.
    public func backupRecords(_ piece: Data, infoRead: Bool, source: String) throws -> BackupRecords {
        let trees = try trees(.backupData, piece, source: source)
        guard trees.count <= MessageParserLimits.maxFrames else { throw MessageParserError.malformed("too many frames") }
        do { try ProtoTree.validateBudget(trees) } catch { throw MessageParserError.malformed("backup reply too large") }
        guard let first = trees.first else { return BackupRecords(info: nil, frames: []) }
        if infoRead { return BackupRecords(info: nil, frames: try trees.map { try Self.decode($0) }) }
        return BackupRecords(info: try Self.decode(first), frames: try trees.dropFirst().map { try Self.decode($0) })
    }

    /// The backup's last piece was read: the parser checks it was complete.
    public func backupEnd(source: String) throws {
        guard try trees(.backupEnd, Data(), source: source).isEmpty else { throw MessageParserError.malformed("records after the end") }
    }
}

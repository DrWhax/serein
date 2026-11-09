// A message's body ranges (`bodyRanges`): mentions (the U+FFFC placeholder at `start`, length 1,
// standing for "@name") and styles (bold, italic, spoiler, strikethrough, monospace), in UTF-16
// offsets of the body. Stored on the message as upstream does ({start, length, mentionAci} or
// {start, length, style}) and sent in DataMessage.bodyRanges.

import Foundation
import GRDB
import SignalProtos

public struct MessageBodyRange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case mention(aci: String)
        /// `BodyRange.Style`: 1 bold, 2 italic, 3 spoiler, 4 strikethrough, 5 monospace.
        case style(Int)
    }

    public var start: Int
    public var length: Int
    public var kind: Kind

    public init(start: Int, length: Int, kind: Kind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    var json: [String: Any] {
        var out: [String: Any] = ["start": start, "length": length]
        switch kind {
        case .mention(let aci): out["mentionAci"] = aci
        case .style(let s): out["style"] = s
        }
        return out
    }

    static func from(_ j: [String: Any]) -> MessageBodyRange? {
        guard let start = (j["start"] as? NSNumber)?.intValue, let length = (j["length"] as? NSNumber)?.intValue, start >= 0, length >= 0 else { return nil }
        if let aci = j["mentionAci"] as? String { return MessageBodyRange(start: start, length: length, kind: .mention(aci: aci)) }
        if let style = (j["style"] as? NSNumber)?.intValue, (1...5).contains(style) { return MessageBodyRange(start: start, length: length, kind: .style(style)) }
        return nil
    }

    var proto: Signalservice_BodyRange {
        var r = Signalservice_BodyRange()
        r.start = UInt32(clamping: start)
        r.length = UInt32(clamping: length)
        switch kind {
        case .mention(let aci): r.mentionAci = aci
        case .style(let s): r.style = Signalservice_BodyRange.Style(rawValue: s) ?? .none
        }
        return r
    }

    /// Only ranges inside the body (UTF-16 length `bodyLength`) are kept.
    static func valid(_ ranges: [MessageBodyRange], bodyLength: Int) -> [MessageBodyRange] {
        ranges.filter { $0.length > 0 && $0.start + $0.length <= bodyLength }
    }
}

extension Messenger {
    /// The stored ranges of an outgoing message, for its DataMessage.
    func storedBodyRanges(messageId: String) async throws -> [Signalservice_BodyRange] {
        try await database.pool.read { db in
            guard let s = try String.fetchOne(db, sql: "SELECT json ->> '$.bodyRanges' FROM messages WHERE id = ?", arguments: [messageId]),
                  let list = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]] else { return [] }
            return list.compactMap(MessageBodyRange.from).map(\.proto)
        }
    }
}

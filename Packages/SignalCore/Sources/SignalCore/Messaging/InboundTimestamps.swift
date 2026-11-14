// Protocol timestamps are unsigned; SQL and interval arithmetic are signed. Validate before
// dispatch, including nested modifier/sync timestamps, so a valid protobuf cannot trap the app.
// IDs (call IDs, CDN IDs) and payment amounts retain their full unsigned range.
import Foundation
import SignalProtos
import SwiftProtobuf

/// A generous signed range with room for timestamp differences and UInt32-second intervals.
/// This excludes only values hundreds of millions of years away, not legitimate message dates.
enum InboundTimestamps {
    static let maximum = UInt64(Int64.max / 2)
    static func check(_ value: UInt64) throws {
        guard value <= maximum else { throw ReceiveError.invalidEnvelope("timestamp outside signed storage range") }
    }
    static func validate<M: SwiftProtobuf.Message>(_ message: M) throws {
        var visitor = Visitor(message: M.protoMessageName, depth: 0)
        try message.traverse(visitor: &visitor)
    }

    // Field numbers from SignalService.pb.swift. Keep timestamp coverage in sync with the
    // schema; a quote's id is also a sent timestamp, unlike a call's random 64-bit id.
    static let fields: [String: Set<Int>] = [
        Signalservice_Envelope.protoMessageName: [5, 10], // clientTimestamp, serverTimestamp
        Signalservice_DataMessage.protoMessageName: [7], // timestamp
        Signalservice_DataMessage.Quote.protoMessageName: [1], // id
        Signalservice_DataMessage.Reaction.protoMessageName: [5], // targetSentTimestamp
        Signalservice_DataMessage.Delete.protoMessageName: [1], // targetSentTimestamp
        Signalservice_DataMessage.StoryContext.protoMessageName: [2], // sentTimestamp
        Signalservice_DataMessage.PollTerminate.protoMessageName: [1], // targetSentTimestamp
        Signalservice_DataMessage.PollVote.protoMessageName: [2], // targetSentTimestamp
        Signalservice_DataMessage.PinMessage.protoMessageName: [2], // targetSentTimestamp
        Signalservice_DataMessage.UnpinMessage.protoMessageName: [2], // targetSentTimestamp
        Signalservice_DataMessage.AdminDelete.protoMessageName: [2], // targetSentTimestamp
        Signalservice_ReceiptMessage.protoMessageName: [2], // timestamp
        Signalservice_TypingMessage.protoMessageName: [1], // timestamp
        Signalservice_Preview.protoMessageName: [5], // date
        Signalservice_SyncMessage.Sent.protoMessageName: [2, 4], // timestamp, expirationStartTimestamp
        Signalservice_SyncMessage.Blocked.BlockedE164.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.Blocked.BlockedAci.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.Blocked.BlockedGroup.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.Read.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.Viewed.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.ViewOnceOpen.protoMessageName: [2], // timestamp
        Signalservice_SyncMessage.OutgoingPayment.MobileCoin.protoMessageName: [5], // ledgerBlockTimestamp
        Signalservice_SyncMessage.CallEvent.protoMessageName: [3], // timestamp
        Signalservice_SyncMessage.CallLogEvent.protoMessageName: [2], // timestamp
        Signalservice_AttachmentPointer.protoMessageName: [13], // uploadTimestamp
        Signalservice_DecryptionErrorMessage.protoMessageName: [2], // timestamp
        Signalservice_EditMessage.protoMessageName: [1], // targetSentTimestamp
        Signalservice_AddressableMessage.protoMessageName: [3], // sentTimestamp
    ]

    struct Visitor: SwiftProtobuf.Visitor {
        let message: String
        let depth: Int
        mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
            if fields[message]?.contains(fieldNumber) == true { try check(value) }
        }
        mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {}
        mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {}
        mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {}
        mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {}
        mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {}
        mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {}
        mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
            guard depth < 64 else { throw ReceiveError.invalidEnvelope("timestamp validation depth") }
            var visitor = Visitor(message: M.protoMessageName, depth: depth + 1)
            try value.traverse(visitor: &visitor)
        }
        mutating func visitSingularGroupField<G: SwiftProtobuf.Message>(value: G, fieldNumber: Int) throws {
            throw ReceiveError.invalidEnvelope("unexpected group")
        }
        mutating func visitMapField<K, V: MapValueType>(fieldType: _ProtobufMap<K, V>.Type, value: _ProtobufMap<K, V>.BaseType, fieldNumber: Int) throws {
            throw ReceiveError.invalidEnvelope("unexpected map")
        }
        mutating func visitMapField<K, V>(fieldType: _ProtobufEnumMap<K, V>.Type, value: _ProtobufEnumMap<K, V>.BaseType, fieldNumber: Int) throws where V.RawValue == Int {
            throw ReceiveError.invalidEnvelope("unexpected map")
        }
        mutating func visitMapField<K, V>(fieldType: _ProtobufMessageMap<K, V>.Type, value: _ProtobufMessageMap<K, V>.BaseType, fieldNumber: Int) throws {
            throw ReceiveError.invalidEnvelope("unexpected map")
        }
        mutating func visitExtensionFields(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
        mutating func visitExtensionFieldsAsMessageSet(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
        mutating func visitUnknown(bytes: Data) throws {}
    }
}

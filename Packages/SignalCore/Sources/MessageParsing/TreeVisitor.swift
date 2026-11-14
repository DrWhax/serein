// The service's side: a message SwiftProtobuf has parsed, written out as a ProtoTree. Only the
// fields the schema knows are written (unknown fields are dropped), each value as the node kind
// its type has on the wire, so TreeDecoder can check every value against what the schema asks.

import Foundation
import SwiftProtobuf

extension ProtoTree {
    /// `message`'s known fields.
    public init(_ message: some SwiftProtobuf.Message) throws {
        let builder = TreeBuilder()
        var visitor = TreeVisitor(builder: builder, parent: 0, depth: 0)
        try message.traverse(visitor: &visitor)
        self.init(nodes: builder.nodes)
    }
}

final class TreeBuilder {
    var nodes = [ProtoTree.Node(parent: 0, field: 0, kind: .message)]

    func add(_ parent: UInt32, _ field: Int, _ kind: ProtoTree.Kind, bits: UInt64 = 0, bytes: Data = Data()) throws -> UInt32 {
        guard nodes.count < ProtoTree.Limits.maxNodes else { throw ProtoTree.TreeError.tooLarge }
        guard let f = UInt32(exactly: field), f >= 1, f <= ProtoTree.Limits.maxField else { throw ProtoTree.TreeError.malformed("field \(field)") }
        nodes.append(ProtoTree.Node(parent: parent, field: f, kind: kind, bits: bits, bytes: bytes))
        return UInt32(nodes.count - 1)
    }
}

struct TreeVisitor: SwiftProtobuf.Visitor {
    let builder: TreeBuilder
    let parent: UInt32
    let depth: Int

    mutating func int(_ v: Int64, _ field: Int) throws { _ = try builder.add(parent, field, .varint, bits: UInt64(bitPattern: v)) }
    mutating func uint(_ v: UInt64, _ field: Int) throws { _ = try builder.add(parent, field, .varint, bits: v) }
    mutating func f32(_ v: UInt32, _ field: Int) throws { _ = try builder.add(parent, field, .fixed32, bits: UInt64(v)) }
    mutating func f64(_ v: UInt64, _ field: Int) throws { _ = try builder.add(parent, field, .fixed64, bits: v) }
    mutating func data(_ v: Data, _ field: Int) throws { _ = try builder.add(parent, field, .bytes, bytes: v) }
    mutating func message(_ m: some SwiftProtobuf.Message, _ field: Int) throws {
        guard depth + 1 < ProtoTree.Limits.maxDepth else { throw ProtoTree.TreeError.tooDeep }
        let index = try builder.add(parent, field, .message)
        var sub = TreeVisitor(builder: builder, parent: index, depth: depth + 1)
        try m.traverse(visitor: &sub)
    }

    mutating func visitSingularFloatField(value: Float, fieldNumber: Int) throws { try f32(value.bitPattern, fieldNumber) }
    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws { try f64(value.bitPattern, fieldNumber) }
    mutating func visitSingularInt32Field(value: Int32, fieldNumber: Int) throws { try int(Int64(value), fieldNumber) }
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws { try int(value, fieldNumber) }
    mutating func visitSingularUInt32Field(value: UInt32, fieldNumber: Int) throws { try uint(UInt64(value), fieldNumber) }
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws { try uint(value, fieldNumber) }
    mutating func visitSingularSInt32Field(value: Int32, fieldNumber: Int) throws { try int(Int64(value), fieldNumber) }
    mutating func visitSingularSInt64Field(value: Int64, fieldNumber: Int) throws { try int(value, fieldNumber) }
    mutating func visitSingularFixed32Field(value: UInt32, fieldNumber: Int) throws { try f32(value, fieldNumber) }
    mutating func visitSingularFixed64Field(value: UInt64, fieldNumber: Int) throws { try f64(value, fieldNumber) }
    mutating func visitSingularSFixed32Field(value: Int32, fieldNumber: Int) throws { try f32(UInt32(bitPattern: value), fieldNumber) }
    mutating func visitSingularSFixed64Field(value: Int64, fieldNumber: Int) throws { try f64(UInt64(bitPattern: value), fieldNumber) }
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws { try uint(value ? 1 : 0, fieldNumber) }
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws { try data(Data(value.utf8), fieldNumber) }
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws { try data(value, fieldNumber) }
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws { try int(Int64(value.rawValue), fieldNumber) }
    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws { try message(value, fieldNumber) }
    mutating func visitSingularGroupField<G: SwiftProtobuf.Message>(value: G, fieldNumber: Int) throws {
        throw ProtoTree.TreeError.malformed("groups are not part of Signal's protocol")
    }

    mutating func visitRepeatedFloatField(value: [Float], fieldNumber: Int) throws { for v in value { try f32(v.bitPattern, fieldNumber) } }
    mutating func visitRepeatedDoubleField(value: [Double], fieldNumber: Int) throws { for v in value { try f64(v.bitPattern, fieldNumber) } }
    mutating func visitRepeatedInt32Field(value: [Int32], fieldNumber: Int) throws { for v in value { try int(Int64(v), fieldNumber) } }
    mutating func visitRepeatedInt64Field(value: [Int64], fieldNumber: Int) throws { for v in value { try int(v, fieldNumber) } }
    mutating func visitRepeatedUInt32Field(value: [UInt32], fieldNumber: Int) throws { for v in value { try uint(UInt64(v), fieldNumber) } }
    mutating func visitRepeatedUInt64Field(value: [UInt64], fieldNumber: Int) throws { for v in value { try uint(v, fieldNumber) } }
    mutating func visitRepeatedSInt32Field(value: [Int32], fieldNumber: Int) throws { for v in value { try int(Int64(v), fieldNumber) } }
    mutating func visitRepeatedSInt64Field(value: [Int64], fieldNumber: Int) throws { for v in value { try int(v, fieldNumber) } }
    mutating func visitRepeatedFixed32Field(value: [UInt32], fieldNumber: Int) throws { for v in value { try f32(v, fieldNumber) } }
    mutating func visitRepeatedFixed64Field(value: [UInt64], fieldNumber: Int) throws { for v in value { try f64(v, fieldNumber) } }
    mutating func visitRepeatedSFixed32Field(value: [Int32], fieldNumber: Int) throws { for v in value { try f32(UInt32(bitPattern: v), fieldNumber) } }
    mutating func visitRepeatedSFixed64Field(value: [Int64], fieldNumber: Int) throws { for v in value { try f64(UInt64(bitPattern: v), fieldNumber) } }
    mutating func visitRepeatedBoolField(value: [Bool], fieldNumber: Int) throws { for v in value { try uint(v ? 1 : 0, fieldNumber) } }
    mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws { for v in value { try data(Data(v.utf8), fieldNumber) } }
    mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws { for v in value { try data(v, fieldNumber) } }
    mutating func visitRepeatedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws { for v in value { try int(Int64(v.rawValue), fieldNumber) } }
    mutating func visitRepeatedMessageField<M: SwiftProtobuf.Message>(value: [M], fieldNumber: Int) throws { for v in value { try message(v, fieldNumber) } }
    mutating func visitRepeatedGroupField<G: SwiftProtobuf.Message>(value: [G], fieldNumber: Int) throws {
        throw ProtoTree.TreeError.malformed("groups are not part of Signal's protocol")
    }

    // Packed fields are the same values, one node each.
    mutating func visitPackedFloatField(value: [Float], fieldNumber: Int) throws { try visitRepeatedFloatField(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedDoubleField(value: [Double], fieldNumber: Int) throws { try visitRepeatedDoubleField(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedInt32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedInt64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedUInt32Field(value: [UInt32], fieldNumber: Int) throws { try visitRepeatedUInt32Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedUInt64Field(value: [UInt64], fieldNumber: Int) throws { try visitRepeatedUInt64Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedSInt32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedSInt32Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedSInt64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedSInt64Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedFixed32Field(value: [UInt32], fieldNumber: Int) throws { try visitRepeatedFixed32Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedFixed64Field(value: [UInt64], fieldNumber: Int) throws { try visitRepeatedFixed64Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedSFixed32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedSFixed32Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedSFixed64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedSFixed64Field(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedBoolField(value: [Bool], fieldNumber: Int) throws { try visitRepeatedBoolField(value: value, fieldNumber: fieldNumber) }
    mutating func visitPackedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws { try visitRepeatedEnumField(value: value, fieldNumber: fieldNumber) }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(fieldType: _ProtobufMap<KeyType, ValueType>.Type, value: _ProtobufMap<KeyType, ValueType>.BaseType,
                                                                  fieldNumber: Int) throws {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func visitMapField<KeyType, ValueType>(fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type, value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
                                                    fieldNumber: Int) throws where ValueType.RawValue == Int {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func visitMapField<KeyType, ValueType>(fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type, value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
                                                    fieldNumber: Int) throws {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func visitExtensionFields(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
    mutating func visitExtensionFieldsAsMessageSet(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}
    /// Unknown fields are not passed on.
    mutating func visitUnknown(bytes: Data) throws {}
}

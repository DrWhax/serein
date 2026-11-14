// The app's side: a typed message read back from a validated ProtoTree through SwiftProtobuf's
// Decoder protocol, so the generated code fills the message as it would from protobuf bytes,
// but the app never runs a protobuf byte parser on what the service sent. Each value must have
// the node kind its field's type asks for; a string must be UTF-8; recursion follows the tree,
// whose depth `validated()` bounded.

import Foundation
import SwiftProtobuf

extension ProtoTree.Validated {
    /// The root as a message of type `M` (which must then be complete: no missing required field).
    public func decode<M: SwiftProtobuf.Message>(_ type: M.Type = M.self) throws -> M {
        var decoder = TreeDecoder(tree: self, fields: children[0])
        var m = M()
        try m.decodeMessage(decoder: &decoder)
        guard m.isInitialized else { throw ProtoTree.TreeError.malformed("a required field is missing") }
        return m
    }
}

struct TreeDecoder: SwiftProtobuf.Decoder {
    let tree: ProtoTree.Validated
    /// This message's field nodes, in order.
    let fields: [Int]
    var position = 0
    /// The node of the field the generated code is decoding now.
    var current = 0
    var singularFields: Set<UInt32> = []

    /// TreeVisitor emits each singular field once. Duplicate singular nodes from an untrusted
    /// helper are not protobuf byte input: merging them can repeatedly copy growing messages.
    mutating func singular() throws {
        let field = tree.tree.nodes[current].f
        guard singularFields.insert(field).inserted else { throw ProtoTree.TreeError.malformed("duplicate singular field \(field)") }
    }

    init(tree: ProtoTree.Validated, fields: [Int]) {
        self.tree = tree
        self.fields = fields
    }

    mutating func handleConflictingOneOf() throws {
        throw ProtoTree.TreeError.malformed("conflicting oneof in canonical tree")
    }

    mutating func nextFieldNumber() throws -> Int? {
        guard position < fields.count else { return nil }
        current = fields[position]
        position += 1
        return Int(tree.tree.nodes[current].f)
    }

    func node(_ kind: ProtoTree.Kind) throws -> ProtoTree.Node {
        let n = tree.tree.nodes[current]
        guard n.k == kind else { throw ProtoTree.TreeError.malformed("field \(n.f) is \(n.k), not \(kind)") }
        return n
    }
    func varint() throws -> UInt64 { try node(.varint).v }
    func signed() throws -> Int64 { Int64(bitPattern: try varint()) }
    func fixed32() throws -> UInt32 { UInt32(truncatingIfNeeded: try node(.fixed32).v) }
    func fixed64() throws -> UInt64 { try node(.fixed64).v }
    func bytes() throws -> Data { try node(.bytes).d }
    func string() throws -> String {
        guard let s = String(validating: try bytes(), as: UTF8.self) else { throw ProtoTree.TreeError.malformed("a string that is not UTF-8") }
        return s
    }
    func message<M: SwiftProtobuf.Message>(into m: inout M) throws {
        _ = try node(.message)
        var sub = TreeDecoder(tree: tree, fields: tree.children[current])
        try m.decodeMessage(decoder: &sub)
    }

    mutating func decodeSingularFloatField(value: inout Float) throws { try singular(); value = Float(bitPattern: try fixed32()) }
    mutating func decodeSingularFloatField(value: inout Float?) throws { try singular(); value = Float(bitPattern: try fixed32()) }
    mutating func decodeRepeatedFloatField(value: inout [Float]) throws { value.append(Float(bitPattern: try fixed32())) }
    mutating func decodeSingularDoubleField(value: inout Double) throws { try singular(); value = Double(bitPattern: try fixed64()) }
    mutating func decodeSingularDoubleField(value: inout Double?) throws { try singular(); value = Double(bitPattern: try fixed64()) }
    mutating func decodeRepeatedDoubleField(value: inout [Double]) throws { value.append(Double(bitPattern: try fixed64())) }
    mutating func decodeSingularInt32Field(value: inout Int32) throws { try singular(); value = Int32(truncatingIfNeeded: try signed()) }
    mutating func decodeSingularInt32Field(value: inout Int32?) throws { try singular(); value = Int32(truncatingIfNeeded: try signed()) }
    mutating func decodeRepeatedInt32Field(value: inout [Int32]) throws { value.append(Int32(truncatingIfNeeded: try signed())) }
    mutating func decodeSingularInt64Field(value: inout Int64) throws { try singular(); value = try signed() }
    mutating func decodeSingularInt64Field(value: inout Int64?) throws { try singular(); value = try signed() }
    mutating func decodeRepeatedInt64Field(value: inout [Int64]) throws { value.append(try signed()) }
    mutating func decodeSingularUInt32Field(value: inout UInt32) throws { try singular(); value = UInt32(truncatingIfNeeded: try varint()) }
    mutating func decodeSingularUInt32Field(value: inout UInt32?) throws { try singular(); value = UInt32(truncatingIfNeeded: try varint()) }
    mutating func decodeRepeatedUInt32Field(value: inout [UInt32]) throws { value.append(UInt32(truncatingIfNeeded: try varint())) }
    mutating func decodeSingularUInt64Field(value: inout UInt64) throws { try singular(); value = try varint() }
    mutating func decodeSingularUInt64Field(value: inout UInt64?) throws { try singular(); value = try varint() }
    mutating func decodeRepeatedUInt64Field(value: inout [UInt64]) throws { value.append(try varint()) }
    // The tree holds sint values themselves (no zigzag: that is a byte encoding).
    mutating func decodeSingularSInt32Field(value: inout Int32) throws { try singular(); value = Int32(truncatingIfNeeded: try signed()) }
    mutating func decodeSingularSInt32Field(value: inout Int32?) throws { try singular(); value = Int32(truncatingIfNeeded: try signed()) }
    mutating func decodeRepeatedSInt32Field(value: inout [Int32]) throws { value.append(Int32(truncatingIfNeeded: try signed())) }
    mutating func decodeSingularSInt64Field(value: inout Int64) throws { try singular(); value = try signed() }
    mutating func decodeSingularSInt64Field(value: inout Int64?) throws { try singular(); value = try signed() }
    mutating func decodeRepeatedSInt64Field(value: inout [Int64]) throws { value.append(try signed()) }
    mutating func decodeSingularFixed32Field(value: inout UInt32) throws { try singular(); value = try fixed32() }
    mutating func decodeSingularFixed32Field(value: inout UInt32?) throws { try singular(); value = try fixed32() }
    mutating func decodeRepeatedFixed32Field(value: inout [UInt32]) throws { value.append(try fixed32()) }
    mutating func decodeSingularFixed64Field(value: inout UInt64) throws { try singular(); value = try fixed64() }
    mutating func decodeSingularFixed64Field(value: inout UInt64?) throws { try singular(); value = try fixed64() }
    mutating func decodeRepeatedFixed64Field(value: inout [UInt64]) throws { value.append(try fixed64()) }
    mutating func decodeSingularSFixed32Field(value: inout Int32) throws { try singular(); value = Int32(bitPattern: try fixed32()) }
    mutating func decodeSingularSFixed32Field(value: inout Int32?) throws { try singular(); value = Int32(bitPattern: try fixed32()) }
    mutating func decodeRepeatedSFixed32Field(value: inout [Int32]) throws { value.append(Int32(bitPattern: try fixed32())) }
    mutating func decodeSingularSFixed64Field(value: inout Int64) throws { try singular(); value = Int64(bitPattern: try fixed64()) }
    mutating func decodeSingularSFixed64Field(value: inout Int64?) throws { try singular(); value = Int64(bitPattern: try fixed64()) }
    mutating func decodeRepeatedSFixed64Field(value: inout [Int64]) throws { value.append(Int64(bitPattern: try fixed64())) }
    mutating func decodeSingularBoolField(value: inout Bool) throws { try singular(); value = try varint() != 0 }
    mutating func decodeSingularBoolField(value: inout Bool?) throws { try singular(); value = try varint() != 0 }
    mutating func decodeRepeatedBoolField(value: inout [Bool]) throws { value.append(try varint() != 0) }
    mutating func decodeSingularStringField(value: inout String) throws { try singular(); value = try string() }
    mutating func decodeSingularStringField(value: inout String?) throws { try singular(); value = try string() }
    mutating func decodeRepeatedStringField(value: inout [String]) throws { value.append(try string()) }
    mutating func decodeSingularBytesField(value: inout Data) throws { try singular(); value = try bytes() }
    mutating func decodeSingularBytesField(value: inout Data?) throws { try singular(); value = try bytes() }
    mutating func decodeRepeatedBytesField(value: inout [Data]) throws { value.append(try bytes()) }

    // An enum value the schema does not name is dropped, as protobuf drops it from a closed enum.
    func enumValue<E: SwiftProtobuf.Enum>(_ type: E.Type) throws -> E? where E.RawValue == Int {
        guard let raw = Int32(exactly: try signed()) else { return nil }
        return E(rawValue: Int(raw))
    }
    mutating func decodeSingularEnumField<E: SwiftProtobuf.Enum>(value: inout E) throws where E.RawValue == Int { try singular();
        if let v = try enumValue(E.self) { value = v }
    }
    mutating func decodeSingularEnumField<E: SwiftProtobuf.Enum>(value: inout E?) throws where E.RawValue == Int { try singular();
        if let v = try enumValue(E.self) { value = v }
    }
    mutating func decodeRepeatedEnumField<E: SwiftProtobuf.Enum>(value: inout [E]) throws where E.RawValue == Int {
        if let v = try enumValue(E.self) { value.append(v) }
    }

    mutating func decodeSingularMessageField<M: SwiftProtobuf.Message>(value: inout M?) throws { try singular();
        var m = value ?? M()
        try message(into: &m)
        value = m
    }
    mutating func decodeRepeatedMessageField<M: SwiftProtobuf.Message>(value: inout [M]) throws {
        var m = M()
        try message(into: &m)
        value.append(m)
    }
    mutating func decodeSingularGroupField<G: SwiftProtobuf.Message>(value: inout G?) throws { try singular();
        throw ProtoTree.TreeError.malformed("groups are not part of Signal's protocol")
    }
    mutating func decodeRepeatedGroupField<G: SwiftProtobuf.Message>(value: inout [G]) throws {
        throw ProtoTree.TreeError.malformed("groups are not part of Signal's protocol")
    }

    mutating func decodeMapField<KeyType, ValueType: MapValueType>(fieldType: _ProtobufMap<KeyType, ValueType>.Type,
                                                                   value: inout _ProtobufMap<KeyType, ValueType>.BaseType) throws {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func decodeMapField<KeyType, ValueType>(fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
                                                     value: inout _ProtobufEnumMap<KeyType, ValueType>.BaseType) throws where ValueType.RawValue == Int {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func decodeMapField<KeyType, ValueType>(fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
                                                     value: inout _ProtobufMessageMap<KeyType, ValueType>.BaseType) throws {
        throw ProtoTree.TreeError.malformed("maps are not part of Signal's messages")
    }
    mutating func decodeExtensionField(values: inout ExtensionFieldValueSet, messageType: any SwiftProtobuf.Message.Type, fieldNumber: Int) throws {}
}

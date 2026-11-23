import Foundation

package enum CallingWireError: Error {
    case malformed, tooLarge, unsupportedVersion
}

/// Reads the proto2 wire types used by RingRTC. Nested messages borrow the input's storage.
/// The input budget applies to the entire envelope, before any field is copied.
package struct CallingProtoReader {
    package static let byteLimit = 64 * 1024
    private var remaining: ArraySlice<UInt8>

    package init(_ envelope: Data, limit: Int = Self.byteLimit) throws {
        guard envelope.count <= limit else { throw CallingWireError.tooLarge }
        remaining = Array(envelope)[...]
    }

    package init(_ field: ArraySlice<UInt8>) { remaining = field }

    package struct Tag {
        package let number: Int
        package let wire: UInt8
    }

    package mutating func next() throws -> Tag? {
        guard !remaining.isEmpty else { return nil }
        let value = try varint()
        guard value >= 8, value <= UInt32.max else { throw CallingWireError.malformed }
        return Tag(number: Int(value >> 3), wire: UInt8(value & 7))
    }

    private mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard let byte = remaining.popFirst(), shift < 63 || byte <= 1 else { throw CallingWireError.malformed }
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
        }
        throw CallingWireError.malformed
    }

    package mutating func integer(_ tag: Tag) throws -> UInt64 {
        guard tag.wire == 0 else { throw CallingWireError.malformed }
        return try varint()
    }

    private mutating func take(_ count: UInt64) throws -> ArraySlice<UInt8> {
        guard count <= remaining.count else { throw CallingWireError.malformed }
        let field = remaining.prefix(Int(count))
        remaining = remaining.dropFirst(Int(count))
        return field
    }

    package mutating func uint32(_ tag: Tag) throws -> UInt32 {
        guard let value = try UInt32(exactly: integer(tag)) else { throw CallingWireError.malformed }
        return value
    }

    package mutating func fixed32(_ tag: Tag) throws -> UInt32 {
        guard tag.wire == 5 else { throw CallingWireError.malformed }
        var value: UInt32 = 0
        for (index, byte) in try take(4).enumerated() { value |= UInt32(byte) << (index * 8) }
        return value
    }

    /// Prost accepts both packed and unpacked repeated scalar fields.
    package mutating func repeatedUInt32(_ tag: Tag, fixed: Bool, into values: inout [UInt32]) throws {
        if tag.wire == 2 {
            var packed = try CallingProtoReader(bytes(tag))
            let element = Tag(number: tag.number, wire: fixed ? 5 : 0)
            while !packed.remaining.isEmpty {
                guard values.count < 4096 else { throw CallingWireError.tooLarge }
                values.append(try fixed ? packed.fixed32(element) : packed.uint32(element))
            }
        } else {
            guard values.count < 4096 else { throw CallingWireError.tooLarge }
            values.append(try fixed ? fixed32(tag) : uint32(tag))
        }
    }

    package mutating func message(_ tag: Tag, _ read: (Tag, inout CallingProtoReader) throws -> Void) throws {
        var nested = try CallingProtoReader(bytes(tag))
        while let field = try nested.next() { try read(field, &nested) }
    }

    package mutating func fixed64(_ tag: Tag) throws -> UInt64 {
        guard tag.wire == 1 else { throw CallingWireError.malformed }
        var value: UInt64 = 0
        for (index, byte) in try take(8).enumerated() { value |= UInt64(byte) << (index * 8) }
        return value
    }

    package mutating func bytes(_ tag: Tag) throws -> ArraySlice<UInt8> {
        guard tag.wire == 2 else { throw CallingWireError.malformed }
        let length = try varint()
        return try take(length)
    }

    package mutating func string(_ tag: Tag) throws -> String {
        guard let value = try String(validating: bytes(tag), as: UTF8.self) else { throw CallingWireError.malformed }
        return value
    }

    package mutating func skip(_ tag: Tag, depth: Int = 0) throws {
        switch tag.wire {
        case 0: _ = try varint()
        case 1: _ = try take(8)
        case 2: _ = try bytes(tag)
        case 3:
            guard depth < 16 else { throw CallingWireError.tooLarge }
            while let nested = try next() {
                if nested.wire == 4 {
                    guard nested.number == tag.number else { throw CallingWireError.malformed }
                    return
                }
                try skip(nested, depth: depth + 1)
            }
            throw CallingWireError.malformed
        case 5: _ = try take(4)
        default: throw CallingWireError.malformed
        }
    }
}

package struct CallingProtoWriter {
    package init() {}
    package private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var rest = value
        while rest >= 128 {
            data.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }

    package mutating func integer(_ field: UInt32, _ value: UInt64) {
        varint(UInt64(field) << 3)
        varint(value)
    }

    package mutating func fixed32(_ field: UInt32, _ value: UInt32) {
        varint(UInt64(field) << 3 | 5)
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    package mutating func fixed64(_ field: UInt32, _ value: UInt64) {
        varint(UInt64(field) << 3 | 1)
        for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    package mutating func bytes(_ field: UInt32, _ value: some Collection<UInt8>) {
        varint(UInt64(field) << 3 | 2)
        varint(UInt64(value.count))
        data.append(contentsOf: value)
    }
}

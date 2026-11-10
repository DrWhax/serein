// The XPC wire format between Serein's processes: what every request and reply is encoded in.
// Each side treats the other's bytes as hostile, so this is a grammar driven entirely by the
// Swift type the receiver expects, not a self-describing format (the binary plists it replaces
// let the sender pick any object graph, parsed by CoreFoundation's general plist reader):
//
//   message  = "SSW1" value                     nothing may follow
//   Bool     = u8 (0 or 1)
//   integers = 8 bytes, little-endian            narrower types must fit
//   Float    = u32 bits;  Double = u64 bits
//   String   = u32 length, UTF-8 (validated)
//   Data     = u32 length, bytes;  [Float] = u32 count, u32 bits each
//   URL      = String (absolute)
//   Optional = u8 0 | u8 1 value
//   struct / enum case = for each field in declaration order: tag value
//            (tag = u8 length, the field's or case's name; it must be the one expected)
//   array    = u32 count, the elements
//
// Limits come before allocation: the message must fit the caller's `maxBytes` (each call knows
// how large its reply can be) before a byte is read, every length and count is checked against
// what is left, and arrays report no count, so `Array` never reserves memory from a number in
// the message. Dictionaries and class hierarchies are not part of the format.

import Foundation

public enum Wire {
    static let magic: [UInt8] = [0x53, 0x53, 0x57, 0x31]   // "SSW1"
    static let invalid = MediaProcessingError.invalidResult

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let w = WireWriter()
        w.bytes.append(contentsOf: magic)
        try w.write(value)
        return w.bytes
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data, maxBytes: Int) throws -> T {
        guard data.count <= maxBytes, data.count >= magic.count, data.prefix(magic.count).elementsEqual(magic) else { throw invalid }
        let r = WireReader(data, at: data.startIndex + magic.count)
        let value = try r.read(T.self)
        guard r.pos == data.endIndex else { throw invalid }
        return value
    }
}

/// Optionals carry a presence byte wherever they appear (top level, fields, elements).
/// (Dispatched on the static type, never by casting the value: Swift's casts unwrap optionals.)
protocol WireOptional {
    static func wireRead(_ r: WireReader) throws -> Self
    static func wireWrite(_ value: Any, _ w: WireWriter) throws
}

extension Optional: WireOptional where Wrapped: Codable {
    static func wireRead(_ r: WireReader) throws -> Self {
        switch try r.u8() {
        case 0: return nil
        case 1: return try r.read(Wrapped.self)
        default: throw Wire.invalid
        }
    }
    static func wireWrite(_ value: Any, _ w: WireWriter) throws {
        guard let optional = value as? Self else { throw Wire.invalid }
        if let wrapped = optional { w.u8(1); try w.write(wrapped) } else { w.u8(0) }
    }
}

// MARK: - Writing

final class WireWriter: Encoder {
    var bytes = Data()
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func uint(_ v: UInt64, _ n: Int) { for i in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) } }
    func u8(_ v: UInt8) { bytes.append(v) }
    func length(_ n: Int) throws {
        guard n >= 0, n <= Int(UInt32.max) else { throw Wire.invalid }
        uint(UInt64(n), 4)
    }
    func int(_ v: Int64) { uint(UInt64(bitPattern: v), 8) }
    func string(_ s: String) throws {
        let utf8 = Array(s.utf8)
        try length(utf8.count)
        bytes.append(contentsOf: utf8)
    }
    func tag(_ key: some CodingKey) throws {
        let name = Array(key.stringValue.utf8)
        guard name.count <= 255 else { throw Wire.invalid }
        u8(UInt8(name.count))
        bytes.append(contentsOf: name)
    }

    // Primitive values, shared by the three container kinds.
    func put(_ v: Bool) { u8(v ? 1 : 0) }
    func put(_ v: String) throws { try string(v) }
    func put(_ v: Double) { uint(v.bitPattern, 8) }
    func put(_ v: Float) { uint(UInt64(v.bitPattern), 4) }
    func put<I: FixedWidthInteger>(_ v: I) throws {
        if I.isSigned {
            guard let x = Int64(exactly: v) else { throw Wire.invalid }
            int(x)
        } else {
            guard let x = UInt64(exactly: v) else { throw Wire.invalid }
            uint(x, 8)
        }
    }

    /// Special forms by exact static type (a cast like `value as? Data` would also match an
    /// `Optional<Data>`, and Foundation bridges numbers between array types).
    func write<T: Encodable>(_ value: T) throws {
        if let o = T.self as? any WireOptional.Type {
            try o.wireWrite(value, self)
        } else if T.self == Data.self, let d = value as? Data {
            try length(d.count)
            bytes.append(d)
        } else if T.self == URL.self, let url = value as? URL {
            // As its absolute string (URL's own Codable writes `base` only when there is one).
            try string(url.absoluteString)
        } else if T.self == [Float].self, let floats = value as? [Float] {
            try length(floats.count)
            for f in floats { uint(UInt64(f.bitPattern), 4) }
        } else {
            try value.encode(to: self)
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> { KeyedEncodingContainer(WireKeyedWriter<Key>(w: self)) }
    func unkeyedContainer() -> any UnkeyedEncodingContainer { WireUnkeyedWriter(w: self) }
    func singleValueContainer() -> any SingleValueEncodingContainer { WireValueWriter(w: self) }
}

struct WireKeyedWriter<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let w: WireWriter
    var codingPath: [any CodingKey] { w.codingPath }

    mutating func encodeNil(forKey key: Key) throws { try w.tag(key); w.u8(0) }
    mutating func encode(_ v: Bool, forKey key: Key) throws { try w.tag(key); w.put(v) }
    mutating func encode(_ v: String, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: Double, forKey key: Key) throws { try w.tag(key); w.put(v) }
    mutating func encode(_ v: Float, forKey key: Key) throws { try w.tag(key); w.put(v) }
    mutating func encode(_ v: Int, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: Int8, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: Int16, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: Int32, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: Int64, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: UInt, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: UInt8, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: UInt16, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: UInt32, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode(_ v: UInt64, forKey key: Key) throws { try w.tag(key); try w.put(v) }
    mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws { try w.tag(key); try w.write(v) }

    // Optional fields: always present, with a presence byte (no field is ever skipped, so the
    // reader never has to guess whether a tag belongs to this container or the next).
    func opt<T: Encodable>(_ v: T?, _ key: Key) throws {
        try w.tag(key)
        if let v { w.u8(1); try w.write(v) } else { w.u8(0) }
    }
    mutating func encodeIfPresent(_ v: Bool?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: String?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Double?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Float?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Int?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Int8?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Int16?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Int32?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: Int64?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: UInt?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: UInt8?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: UInt16?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: UInt32?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent(_ v: UInt64?, forKey key: Key) throws { try opt(v, key) }
    mutating func encodeIfPresent<T: Encodable>(_ v: T?, forKey key: Key) throws { try opt(v, key) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        // Tags are at most 255 bytes of a Swift identifier; a longer one fails when it is read.
        try? w.tag(key)
        return KeyedEncodingContainer(WireKeyedWriter<NestedKey>(w: w))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        try? w.tag(key)
        return WireUnkeyedWriter(w: w)
    }
    mutating func superEncoder() -> any Encoder { w }
    mutating func superEncoder(forKey key: Key) -> any Encoder { try? w.tag(key); return w }
}

/// The element count is written first as a placeholder and patched after every element.
struct WireUnkeyedWriter: UnkeyedEncodingContainer {
    let w: WireWriter
    let countAt: Int
    var count = 0
    var codingPath: [any CodingKey] { w.codingPath }

    init(w: WireWriter) {
        self.w = w
        countAt = w.bytes.count
        w.uint(0, 4)
    }

    mutating func counted(_ body: (WireWriter) throws -> Void) throws {
        try body(w)
        count += 1
        guard count <= Int(UInt32.max) else { throw Wire.invalid }
        for i in 0..<4 { w.bytes[w.bytes.startIndex + countAt + i] = UInt8(truncatingIfNeeded: count >> (8 * i)) }
    }

    mutating func encodeNil() throws { try counted { $0.u8(0) } }
    mutating func encode(_ v: Bool) throws { try counted { $0.put(v) } }
    mutating func encode(_ v: String) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: Double) throws { try counted { $0.put(v) } }
    mutating func encode(_ v: Float) throws { try counted { $0.put(v) } }
    mutating func encode(_ v: Int) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: Int8) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: Int16) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: Int32) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: Int64) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: UInt) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: UInt8) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: UInt16) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: UInt32) throws { try counted { try $0.put(v) } }
    mutating func encode(_ v: UInt64) throws { try counted { try $0.put(v) } }
    mutating func encode<T: Encodable>(_ v: T) throws { try counted { try $0.write(v) } }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        try? counted { _ in }
        return KeyedEncodingContainer(WireKeyedWriter<NestedKey>(w: w))
    }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        try? counted { _ in }
        return WireUnkeyedWriter(w: w)
    }
    mutating func superEncoder() -> any Encoder { try? counted { _ in }; return w }
}

struct WireValueWriter: SingleValueEncodingContainer {
    let w: WireWriter
    var codingPath: [any CodingKey] { w.codingPath }

    mutating func encodeNil() throws { w.u8(0) }
    mutating func encode(_ v: Bool) throws { w.put(v) }
    mutating func encode(_ v: String) throws { try w.put(v) }
    mutating func encode(_ v: Double) throws { w.put(v) }
    mutating func encode(_ v: Float) throws { w.put(v) }
    mutating func encode(_ v: Int) throws { try w.put(v) }
    mutating func encode(_ v: Int8) throws { try w.put(v) }
    mutating func encode(_ v: Int16) throws { try w.put(v) }
    mutating func encode(_ v: Int32) throws { try w.put(v) }
    mutating func encode(_ v: Int64) throws { try w.put(v) }
    mutating func encode(_ v: UInt) throws { try w.put(v) }
    mutating func encode(_ v: UInt8) throws { try w.put(v) }
    mutating func encode(_ v: UInt16) throws { try w.put(v) }
    mutating func encode(_ v: UInt32) throws { try w.put(v) }
    mutating func encode(_ v: UInt64) throws { try w.put(v) }
    mutating func encode<T: Encodable>(_ v: T) throws { try w.write(v) }
}

// MARK: - Reading

final class WireReader: Decoder {
    let data: Data
    var pos: Int
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(_ data: Data, at pos: Int) {
        self.data = data
        self.pos = pos
    }

    var remaining: Int { data.endIndex - pos }

    func uint(_ n: Int) throws -> UInt64 {
        guard remaining >= n else { throw Wire.invalid }
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(data[pos + i]) << UInt64(8 * i) }
        pos += n
        return v
    }
    func u8() throws -> UInt8 { UInt8(try uint(1)) }
    /// A length or count: never more than what is left of the message.
    func length() throws -> Int {
        let n = Int(try uint(4))
        guard n <= remaining else { throw Wire.invalid }
        return n
    }
    func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw Wire.invalid }
        defer { pos += n }
        return data.subdata(in: pos ..< pos + n)
    }
    func string() throws -> String {
        let n = try length()
        guard let s = String(validating: data[pos ..< pos + n], as: UTF8.self) else { throw Wire.invalid }
        pos += n
        return s
    }
    func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw Wire.invalid
        }
    }
    func double() throws -> Double { Double(bitPattern: try uint(8)) }
    func float() throws -> Float { Float(bitPattern: UInt32(try uint(4))) }
    func integer<I: FixedWidthInteger>(_ type: I.Type) throws -> I {
        let raw = try uint(8)
        let v: I? = I.isSigned ? I(exactly: Int64(bitPattern: raw)) : I(exactly: raw)
        guard let v else { throw Wire.invalid }
        return v
    }

    /// The tag the reader expects next must be there.
    func expect(_ key: some CodingKey) throws {
        let name = Array(key.stringValue.utf8)
        guard try u8() == name.count, remaining >= name.count, data[pos ..< pos + name.count].elementsEqual(name) else { throw Wire.invalid }
        pos += name.count
    }
    /// The next tag's name, unread (an enum's case).
    func peekTag() throws -> String {
        guard remaining >= 1 else { throw Wire.invalid }
        let n = Int(data[pos])
        guard remaining >= 1 + n, let s = String(validating: data[pos + 1 ..< pos + 1 + n], as: UTF8.self) else { throw Wire.invalid }
        return s
    }

    func read<T: Decodable>(_ type: T.Type) throws -> T {
        if let o = T.self as? any WireOptional.Type { return try cast(try o.wireRead(self)) }
        if T.self == Data.self { return try cast(try take(try length())) }
        if T.self == URL.self {
            guard let url = URL(string: try string()) else { throw Wire.invalid }
            return try cast(url)
        }
        if T.self == [Float].self {
            let n = Int(try uint(4))
            guard n <= remaining / 4 else { throw Wire.invalid }
            var out: [Float] = []
            out.reserveCapacity(n)   // bounded by the bytes that are there
            for _ in 0..<n { out.append(try float()) }
            return try cast(out)
        }
        return try T(from: self)
    }
    func cast<T, U>(_ v: U) throws -> T {
        guard let t = v as? T else { throw Wire.invalid }
        return t
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> { KeyedDecodingContainer(WireKeyedReader<Key>(r: self)) }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { try WireUnkeyedReader(r: self) }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { WireValueReader(r: self) }
}

struct WireKeyedReader<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let r: WireReader
    var codingPath: [any CodingKey] { r.codingPath }

    /// Only an enum asks: the one case that follows.
    var allKeys: [Key] { ((try? r.peekTag()).flatMap { Key(stringValue: $0) }).map { [$0] } ?? [] }
    func contains(_ key: Key) -> Bool { (try? r.peekTag()) == key.stringValue }

    func decodeNil(forKey key: Key) throws -> Bool {
        try r.expect(key)
        return try !r.bool()   // a presence byte; the value (if any) is read by decodeIfPresent
    }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try r.expect(key); return try r.bool() }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try r.expect(key); return try r.string() }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try r.expect(key); return try r.double() }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try r.expect(key); return try r.float() }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try r.expect(key); return try r.integer(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try r.expect(key); return try r.integer(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try r.expect(key); return try r.integer(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try r.expect(key); return try r.integer(type) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try r.expect(key); return try r.read(type) }

    func opt<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        try r.expect(key)
        return try r.bool() ? try r.read(type) : nil
    }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try opt(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try opt(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try opt(type, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try opt(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try opt(type, key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try opt(type, key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try opt(type, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try opt(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try opt(type, key) }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { try opt(type, key) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try r.expect(key)
        return KeyedDecodingContainer(WireKeyedReader<NestedKey>(r: r))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try r.expect(key)
        return try WireUnkeyedReader(r: r)
    }
    func superDecoder() throws -> any Decoder { r }
    func superDecoder(forKey key: Key) throws -> any Decoder { try r.expect(key); return r }
}

struct WireUnkeyedReader: UnkeyedDecodingContainer {
    let r: WireReader
    let total: Int
    var currentIndex = 0
    var codingPath: [any CodingKey] { r.codingPath }
    /// Unknown on purpose: `Array` would reserve this many elements up front.
    var count: Int? { nil }
    var isAtEnd: Bool { currentIndex >= total }

    init(r: WireReader) throws {
        self.r = r
        total = try r.length()   // at most one element per byte left
    }

    mutating func next<T>(_ body: (WireReader) throws -> T) throws -> T {
        guard !isAtEnd else { throw Wire.invalid }
        let v = try body(r)
        currentIndex += 1
        return v
    }

    mutating func decodeNil() throws -> Bool { false }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try next { try $0.bool() } }
    mutating func decode(_ type: String.Type) throws -> String { try next { try $0.string() } }
    mutating func decode(_ type: Double.Type) throws -> Double { try next { try $0.double() } }
    mutating func decode(_ type: Float.Type) throws -> Float { try next { try $0.float() } }
    mutating func decode(_ type: Int.Type) throws -> Int { try next { try $0.integer(type) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next { try $0.integer(type) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next { try $0.integer(type) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next { try $0.integer(type) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next { try $0.integer(type) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next { try $0.integer(type) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next { try $0.integer(type) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next { try $0.integer(type) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next { try $0.integer(type) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next { try $0.integer(type) } }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next { try $0.read(type) } }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try next { KeyedDecodingContainer(WireKeyedReader<NestedKey>(r: $0)) }
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next { try WireUnkeyedReader(r: $0) } }
    mutating func superDecoder() throws -> any Decoder { try next { $0 } }
}

struct WireValueReader: SingleValueDecodingContainer {
    let r: WireReader
    var codingPath: [any CodingKey] { r.codingPath }

    /// Optionals are read through their presence byte (WireOptional), never through here.
    func decodeNil() -> Bool { false }
    func decode(_ type: Bool.Type) throws -> Bool { try r.bool() }
    func decode(_ type: String.Type) throws -> String { try r.string() }
    func decode(_ type: Double.Type) throws -> Double { try r.double() }
    func decode(_ type: Float.Type) throws -> Float { try r.float() }
    func decode(_ type: Int.Type) throws -> Int { try r.integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try r.integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try r.integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try r.integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try r.integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try r.integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try r.integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try r.integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try r.integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try r.integer(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try r.read(type) }
}

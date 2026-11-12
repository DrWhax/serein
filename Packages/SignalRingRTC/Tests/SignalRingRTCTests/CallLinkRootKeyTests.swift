// The Swift call-link key and era-id functions (CallLinkRootKey.swift) against ringrtc's own
// (its static commands, in this process): random keys, every kind of byte string around the
// two key lengths, formatted keys mangled every way a pasted link can be, and era strings.

import Foundation
import RingRTCNative
import Testing
@testable import SignalRingRTC

struct CallLinkRootKeyTests {
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func native(_ name: String, _ fields: [String: JSONValue]) -> JSONValue? { try? NativeEndpoint.staticCommand(name, fields) }

    /// Byte strings: mostly the two key lengths, with valid and invalid version bytes and
    /// repeated chunks planted, some other lengths.
    static func bytes(_ r: inout Rng) -> [UInt8] {
        let n = [16, 16, 21, 21, 21, 0, 15, 17, 20, 22, 32].randomElement(using: &r)!
        var b = (0..<n).map { _ in UInt8.random(in: 0...255, using: &r) }
        if n == 21 { b[16] = [0x01, 0x81, 0x01, 0x81, 0x00, 0x02, 0x41, 0xC1, 0xFF].randomElement(using: &r)! }
        if n >= 16, Bool.random(using: &r), Int.random(in: 0..<4, using: &r) == 0 {
            let i = Int.random(in: 0..<8, using: &r) * 2, d = UInt8.random(in: 0...15, using: &r)
            b[i] = d << 4 | d
            b[i + 1] = d << 4 | d
        }
        return b
    }

    @Test func bytesValidateFormatAndDeriveAsRingRTCDoes() throws {
        var r = Rng(state: 1)
        var valid = 0, invalid = 0
        for _ in 0..<4000 {
            let b = Data(Self.bytes(&r))
            let ours = try? CallLinkRootKey.fromBytes(b)
            let theirs = Self.native("callLinkRootKeyValidate", ["bytes": .bytes(b)])
            try #require((ours != nil) == (theirs != nil), "validate \(b.map { String($0, radix: 16) })")
            guard let ours else { invalid += 1; continue }
            valid += 1
            #expect(try ours.formatted() == Self.native("callLinkRootKeyToFormattedString", ["bytes": .bytes(b)])?.string)
            #expect(try ours.deriveRoomId() == Self.native("callLinkRootKeyDeriveRoomId", ["bytes": .bytes(b)])?.data)
            #expect(ours.redacted == Self.native("callLinkRootKeyToRedactedString", ["bytes": .bytes(b)])?.string)
            #expect(try CallLinkRootKey.parse(ours.formatted()) == ours)
        }
        #expect(valid > 1000 && invalid > 1000, "valid \(valid) invalid \(invalid)")
    }

    /// Formatted keys mangled: characters swapped for others, case changed, separators added,
    /// dropped or moved, cut short, extended (ringrtc stops reading at a "-" after the last
    /// group), and strings of the alphabet with dashes at random.
    @Test func parseAgreesWithRingRTC() throws {
        var r = Rng(state: 2)
        let alphabet = Array("bcdfghkmnpqrstxz"), other = Array("aeiouyBCDFwj0189-_ é")
        var accepted = 0, refused = 0
        for _ in 0..<6000 {
            var b = Self.bytes(&r)
            if b.count != 16 && b.count != 21 { b = Array(b.prefix(16)) + [UInt8](repeating: 1, count: max(0, 16 - b.count)) }
            let base = (try? CallLinkRootKey(unchecked: Data(b)).formatted()) ?? String((0..<39).map { _ in alphabet.randomElement(using: &r)! })
            var s = Array(base)
            switch Int.random(in: 0..<9, using: &r) {
            case 0: break
            case 1: if !s.isEmpty { s[Int.random(in: 0..<s.count, using: &r)] = other.randomElement(using: &r)! }
            case 2: s = Array(String(s).uppercased())
            case 3: s.insert("-", at: Int.random(in: 0...s.count, using: &r))
            case 4: if let i = s.indices.filter({ s[$0] == "-" }).randomElement(using: &r) { s.remove(at: i) }
            case 5: s = Array(s.prefix(Int.random(in: 0...s.count, using: &r)))
            case 6: s += Array(["-", "-bcdf", "bc", "-x", "--", "-é", ""].randomElement(using: &r)!)
            case 7: s = (0..<Int.random(in: 0...60, using: &r)).map { _ in Int.random(in: 0..<6, using: &r) == 0 ? "-" : alphabet.randomElement(using: &r)! }
            default: if s.count > 2 { s.swapAt(Int.random(in: 0..<s.count, using: &r), Int.random(in: 0..<s.count, using: &r)) }
            }
            let text = String(s)
            let ours = (try? CallLinkRootKey.parse(text))?.bytes
            let theirs = Self.native("callLinkRootKeyParse", ["string": .string(text)])?.data
            try #require(ours == theirs, "parse \(text): ours \(String(describing: ours)) ringrtc \(String(describing: theirs))")
            if ours != nil { accepted += 1 } else { refused += 1 }
        }
        #expect(accepted > 1000 && refused > 1000, "accepted \(accepted) refused \(refused)")
    }

    @Test func generatedKeysAreRingRTCKeys() throws {
        for _ in 0..<200 {
            let k = try CallLinkRootKey.generate()
            #expect(k.bytes.count == 21 && k.bytes[16] == 0x81)
            #expect(Self.native("callLinkRootKeyValidate", ["bytes": .bytes(k.bytes)]) != nil)
            #expect(Self.native("callLinkRootKeyParse", ["string": .string(try k.formatted())])?.data == k.bytes)
            #expect(try CallLinkRootKey.generateAdminPassKey().count == 16)
        }
    }

    @Test func eraIdsAgreeWithRingRTC() throws {
        var r = Rng(state: 3)
        let hex = Array("0123456789abcdefABCDEF")
        var eras = ["", "0000000000000000", "+000000000000000", "+00000000000000a", "ffffffffffffffff", "FFFFFFFFFFFFFFFF", "000000000000000g",
                    "-00000000000000a", "+", "++00000000000000", "é0000000000000", " 0000000000000001"]
        for _ in 0..<3000 {
            switch Int.random(in: 0..<4, using: &r) {
            case 0: eras.append(String((0..<16).map { _ in hex.randomElement(using: &r)! }))
            case 1: eras.append("+" + String((0..<15).map { _ in hex.randomElement(using: &r)! }))
            case 2: eras.append(String((0..<Int.random(in: 0...24, using: &r)).map { _ in hex.randomElement(using: &r)! }))
            default: eras.append(UUID().uuidString)
            }
        }
        for era in eras {
            try #require(callIdFromEra(era) == Self.native("callIdFromEra", ["era": .string(era)])?.uint64, "era \(era)")
        }
    }
}

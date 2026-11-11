// Codec components: production SignalCodecs against the Lean model in Verification/Codecs —
// `ByteCursor` reads, the grammar combinators (random grammars built from `Grammar` and `Parser` on
// random bytes), `BoxGrammar.children` (random box streams: sizes right and wrong, largesize,
// size 0, uuid, truncated mdat, the box budget) and `MSBBitReader` (both policies).
//
// Run through Tools/verify-codecs.sh, or set SEREIN_CODECS_ORACLE to the oracle executable.

import Foundation
import Testing
import CodecCore
@testable import ContainerMP4

enum CodecsOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Codecs").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_CODECS_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    struct Failed: Error {}

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-codecs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

struct Mix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func coin(_ oneIn: Int = 2) -> Bool { below(oneIn) == 0 }
}

func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] })
}

func compareLines(_ lines: [String], model: [String], swift: [String]) {
    var reported = 0
    for (k, (m, s)) in zip(model, swift).enumerated() where m != s {
        reported += 1
        if reported <= 3 { Issue.record("disagree at step \(k) (\(lines[k].prefix(160)))\n  model \(m) | swift \(s)") }
    }
    #expect(model.count == lines.count && reported == 0, "\(reported) of \(lines.count) cases disagree")
}

func kind(_ r: ParseFailure.Reason) -> String {
    switch r {
    case .unexpectedEnd: "end"
    case .mismatch: "mismatch"
    case .invalid: "invalid"
    case .limitExceeded: "limit"
    case .trailingBytes: "trailing"
    default: "other"
    }
}

func failCode(_ f: ParseFailure) -> String { "fail:\(f.offset):\(kind(f.reason))" }

/// A parse result's shape: how many items repetitions produced.
indirect enum Node: Sendable {
    case leaf
    case pair(Node, Node)
    case list([Node])
    var items: Int {
        switch self {
        case .leaf: 0
        case .pair(let a, let b): a.items + b.items
        case .list(let xs): xs.count + xs.reduce(0) { $0 + $1.items }
        }
    }
}

/// A random grammar: its S-expression for the oracle and the production parser.
func randomGrammar(_ r: inout Mix, depth: Int) -> (String, Parser<Node>) {
    func prim(_ r: inout Mix) -> (String, Parser<Node>) {
        let n = r.below(6)
        switch r.below(11) {
        case 0: return ("u8", Grammar.u8.map { _ in .leaf })
        case 1: return ("u16be", Grammar.u16be.map { _ in .leaf })
        case 2: return ("u16le", Grammar.u16le.map { _ in .leaf })
        case 3: return ("u24be", Grammar.u24be.map { _ in .leaf })
        case 4: return ("u32be", Grammar.u32be.map { _ in .leaf })
        case 5: return ("u64be", Parser<Node>("u64be") { (c: inout ByteCursor) throws(ParseFailure) in _ = try c.u64be(); return .leaf })
        case 6: return ("bytes:\(n - 1)", Grammar.bytes("bytes", count: n - 1).map { _ in .leaf })
        case 7: return ("skip:\(n)", Parser<Node>("skip") { (c: inout ByteCursor) throws(ParseFailure) in try c.skip(n); return .leaf })
        case 8: return ("expect:\(hex([UInt8(n)]))", Grammar.literal("lit", [UInt8(n)]).map { _ in .leaf })
        case 9: return ("rest", Parser<Node>("rest") { (c: inout ByteCursor) throws(ParseFailure) in _ = c.rest(); return .leaf })
        default: return ("u32le", Grammar.u32le.map { _ in .leaf })
        }
    }
    if depth == 0 { return prim(&r) }
    let n = r.below(8), m = r.below(5)
    switch r.below(8) {
    case 0, 1: return prim(&r)
    case 2:
        let (sa, a) = randomGrammar(&r, depth: depth - 1), (sb, b) = randomGrammar(&r, depth: depth - 1)
        return ("(seq \(sa) \(sb))", Parser<Node>("seq") { (c: inout ByteCursor) throws(ParseFailure) in .pair(try a.parse(&c), try b.parse(&c)) })
    case 3:
        let (sa, a) = randomGrammar(&r, depth: depth - 1)
        return ("(region \(n - 1) \(sa))", Grammar.region("region", length: n - 1, a))
    case 4:
        let (sa, a) = randomGrammar(&r, depth: depth - 1)
        if m % 2 == 0 { return ("(len u8 \(n * 2) \(sa))", Grammar.lengthPrefixed("len", length: Grammar.u8, maxLength: n * 2, a)) }
        return ("(len u16be \(n * 2) \(sa))", Grammar.lengthPrefixed("len", length: Grammar.u16be, maxLength: n * 2, a))
    case 5:
        let (sa, a) = randomGrammar(&r, depth: depth - 1)
        return ("(rep \(n - 1) \(m) \(sa))", a.repeated(count: n - 1, maxCount: m).map { .list($0) })
    case 6:
        let (sa, a) = randomGrammar(&r, depth: depth - 1)
        return ("(end \(m) \(sa))", a.repeatedToEnd(maxCount: m).map { .list($0) })
    default:
        let (sa, a) = randomGrammar(&r, depth: depth - 1), (sb, b) = randomGrammar(&r, depth: depth - 1)
        return ("(or \(sa) \(sb))", Grammar.oneOf("or", [a, b]))
    }
}

@Suite(.serialized, .enabled(if: CodecsOracle.available, "build the oracle: Tools/verify-codecs.sh, or lake build in Verification/Codecs"))
struct CodecConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_CODECS_CASES"].flatMap { Int($0) } ?? 5000 }

    @Test func randomGrammars() throws {
        var r = Mix(s: 89)
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<Self.count {
            let (sexpr, parser) = randomGrammar(&r, depth: 4)
            let bytes = (0..<r.below(24)).map { _ in UInt8(r.below(8)) }
            lines.append("\(hex(bytes)) | \(sexpr)")
            do throws(ParseFailure) {
                swift.append("ok:\(try parser.parseComplete(bytes).items)")
            } catch {
                swift.append(failCode(error))
            }
        }
        compareLines(lines, model: try CodecsOracle.call("grammar", lines), swift: swift)
    }

    @Test func randomCursors() throws {
        var r = Mix(s: 97)
        var lines: [String] = [], swift: [String] = []
        let ops = ["u8", "u16be", "u16le", "u24be", "u24le", "u32be", "u32le", "u64be", "rest"]
        for _ in 0..<Self.count {
            let bytes = (0..<r.below(30)).map { _ in UInt8(truncatingIfNeeded: r.next()) }
            let start = r.below(bytes.count + 1), stop = start + r.below(bytes.count - start + 1)
            var codes: [String] = []
            for _ in 0..<(1 + r.below(8)) {
                switch r.below(12) {
                case 9: codes.append("bytes:\(r.below(8) - 1)")
                case 10: codes.append("skip:\(r.below(8) - 1)")
                case 11: codes.append("expect:\(hex(r.coin() && stop > start ? [bytes[min(start + r.below(4), bytes.count - 1)]] : [UInt8(r.below(256))]))")
                default: codes.append(ops[r.below(ops.count)])
                }
            }
            lines.append("\(hex(bytes)) | \(start) \(stop) | \(codes.joined(separator: " "))")
            var c = ByteSlice(bytes).cursor()
            // The region [start, stop) as the production sees it: a slice handed out by a cursor.
            try? c.skip(start)
            guard var cur = Optional(c), let region = try? cur.bytes(stop - start) else { swift.append("?"); continue }
            var cursor = region.cursor()
            var out: [String] = []
            for code in codes {
                do throws(ParseFailure) {
                    let parts = code.split(separator: ":").map(String.init)
                    let v: String
                    switch parts[0] {
                    case "u8": v = "num:\(try cursor.u8())"
                    case "u16be": v = "num:\(try cursor.u16be())"
                    case "u16le": v = "num:\(try cursor.u16le())"
                    case "u24be": v = "num:\(try cursor.u24be())"
                    case "u24le": v = "num:\(try cursor.u24le())"
                    case "u32be": v = "num:\(try cursor.u32be())"
                    case "u32le": v = "num:\(try cursor.u32le())"
                    case "u64be": v = "num:\(try cursor.u64be())"
                    case "rest": let s = cursor.rest(); v = "slice:\(s.lowerBound):\(s.upperBound)"
                    case "bytes": let s = try cursor.bytes(Int(parts[1])!); v = "slice:\(s.lowerBound):\(s.upperBound)"
                    case "skip": try cursor.skip(Int(parts[1])!); v = "unit"
                    default:
                        let lit = stride(from: 0, to: parts[1].count, by: 2).map { i -> UInt8 in
                            let s = parts[1].dropFirst(i).prefix(2)
                            return UInt8(s, radix: 16)!
                        }
                        try cursor.expect(lit, "lit")
                        v = "unit"
                    }
                    out.append("\(v)@\(cursor.position)")
                } catch {
                    out.append(failCode(error))
                    break
                }
            }
            swift.append(out.joined(separator: " "))
        }
        compareLines(lines, model: try CodecsOracle.call("cursor", lines), swift: swift)
    }

    /// Box streams: valid boxes and every kind of wrong size, largesize, size 0, uuid, a
    /// truncated mdat; at top level or inside a container; with a budget.
    @Test func randomBoxes() throws {
        var r = Mix(s: 101)
        var lines: [String] = [], swift: [String] = []
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let types: [UInt32] = [FourCC("ftyp"), FourCC("moov"), FourCC("mdat"), FourCC("uuid"), FourCC("free")]
        for _ in 0..<Self.count {
            var bytes: [UInt8] = []
            for _ in 0..<(1 + r.below(5)) {
                let type = types[r.below(types.count)]
                let body = (0..<r.below(12)).map { _ in UInt8(r.below(256)) }
                let header = 8 + (type == FourCC("uuid") ? 16 : 0)
                var total = header + body.count
                switch r.below(10) {
                case 0: total = r.below(header)                    // smaller than its header
                case 1: total += 1 + r.below(20)                    // longer than what follows
                case 2: total = 0                                   // to the end
                default: break
                }
                if r.coin(8) {
                    // largesize
                    bytes += be32(1) + be32(type) + be32(0) + be32(UInt32(total + 8))
                } else {
                    bytes += be32(UInt32(total)) + be32(type)
                }
                if type == FourCC("uuid") { bytes += (0..<16).map { _ in UInt8(r.below(256)) } }
                bytes += body
            }
            if r.coin(4) { bytes = Array(bytes.prefix(r.below(bytes.count + 1))) }
            let top = r.coin(), count = r.below(3), maxBoxes = r.below(6)
            lines.append("\(hex(bytes)) | \(top ? 1 : 0) \(count) \(maxBoxes)")
            var limits = MP4Limits()
            limits.maxBoxes = maxBoxes
            var n = count
            do throws(ParseFailure) {
                let boxes = try BoxGrammar.children(ByteSlice(bytes), topLevel: top, limits: limits, count: &n)
                swift.append("ok:\(n)" + boxes.map { " \($0.type)@\($0.offset):\($0.body.lowerBound):\($0.body.upperBound)" }.joined())
            } catch {
                swift.append(failCode(error))
            }
        }
        compareLines(lines, model: try CodecsOracle.call("boxes", lines), swift: swift)
    }

    @Test func randomBits() throws {
        var r = Mix(s: 103)
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<Self.count {
            let bytes = (0..<r.below(12)).map { _ in UInt8(truncatingIfNeeded: r.next()) }
            let zero = r.coin()
            var reader = MSBBitReader(bytes, policy: zero ? .zeroFill : .fail)
            var codes: [String] = [], out: [String] = []
            var failed = false
            for _ in 0..<(1 + r.below(10)) {
                switch r.below(6) {
                case 0:
                    let n = 1 + r.below(32)
                    codes.append("p:\(n)")
                    if !failed { out.append("\(reader.peek(n))@\(reader.bitPosition)") }
                case 1:
                    codes.append("a")
                    if !failed { reader.alignToByte(); out.append("@\(reader.bitPosition)") }
                default:
                    let n = r.below(33)
                    codes.append("b:\(n)")
                    if !failed {
                        do throws(ParseFailure) {
                            let v = try reader.bits(n, "bits")
                            out.append("\(v)@\(reader.bitPosition)")
                        } catch {
                            out.append(failCode(error))
                            failed = true
                        }
                    }
                }
            }
            lines.append("\(hex(bytes)) | \(zero ? "zero" : "fail") | \(codes.joined(separator: " "))")
            swift.append(out.joined(separator: " "))
        }
        compareLines(lines, model: try CodecsOracle.call("bits", lines), swift: swift)
    }
}

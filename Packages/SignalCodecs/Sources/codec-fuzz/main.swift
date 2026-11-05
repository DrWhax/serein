// codec-fuzz: deterministic, structure-aware mutation fuzzer for SignalCodecs.
//
// Stopgap until libFuzzer is available (Xcode's toolchain lacks the fuzzer
// runtime; the swift.org toolchain has it). Run under AddressSanitizer:
//
//   swift run -c release -Xswiftc -sanitize=address codec-fuzz png <corpus-dir> [iterations] [seed]
//   swift run ... codec-fuzz png <corpus-dir> --dump <seed> <iteration> <out-file>   # reproduce a crash
//
// Every input is derived from (seed, iteration), so a crash report of the form
// "seed S iteration N" is enough to regenerate the exact input with --dump.
//
// Invariant checked: the decoder returns a value or throws ParseFailure. Any trap,
// sanitizer report or hang is a bug.

import CodecCore
import Foundation
import ImagePNG

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// PNG chunk spans in a (possibly malformed) buffer: (start of length field, data length).
func chunkSpans(_ b: [UInt8]) -> [(Int, Int)] {
    var spans: [(Int, Int)] = []
    var i = 8
    while i + 12 <= b.count {
        let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        guard n <= b.count - i - 12 else { break }
        spans.append((i, n))
        i += 12 + n
    }
    return spans
}

func fixCRC(_ b: inout [UInt8], _ span: (Int, Int)) {
    let (at, n) = span
    var crc = CRC32()
    crc.update(Array(b[(at + 4)..<(at + 8 + n)]))
    let v = crc.value
    b[at + 8 + n] = UInt8(v >> 24); b[at + 9 + n] = UInt8(v >> 16 & 0xFF)
    b[at + 10 + n] = UInt8(v >> 8 & 0xFF); b[at + 11 + n] = UInt8(v & 0xFF)
}

let interesting: [UInt8] = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255]

func mutate(_ input: [UInt8], corpus: [[UInt8]], rng: inout SplitMix64) -> [UInt8] {
    var b = input
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        guard !b.isEmpty else { return b }
        let spans = chunkSpans(b)
        switch Int.random(in: 0..<9, using: &rng) {
        case 0:  // bit flip anywhere
            let i = Int.random(in: 0..<b.count, using: &rng)
            b[i] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
        case 1:  // interesting byte anywhere
            b[Int.random(in: 0..<b.count, using: &rng)] = interesting.randomElement(using: &rng)!
        case 2, 3, 4:  // mutate inside a chunk's data and repair its CRC (reaches the decoders)
            guard let s = spans.randomElement(using: &rng), s.1 > 0 else { continue }
            let i = s.0 + 8 + Int.random(in: 0..<s.1, using: &rng)
            if Bool.random(using: &rng) { b[i] ^= 1 << UInt8.random(in: 0..<8, using: &rng) } else { b[i] = interesting.randomElement(using: &rng)! }
            fixCRC(&b, s)
        case 5:  // truncate
            b.removeLast(Int.random(in: 1...max(1, b.count / 4), using: &rng))
        case 6:  // duplicate a chunk
            guard let s = spans.randomElement(using: &rng) else { continue }
            let chunk = Array(b[s.0..<(s.0 + 12 + s.1)])
            let at = (spans.randomElement(using: &rng)?.0) ?? 8
            b.insert(contentsOf: chunk, at: at)
        case 7:  // delete a chunk
            guard let s = spans.randomElement(using: &rng) else { continue }
            b.removeSubrange(s.0..<(s.0 + 12 + s.1))
        default:  // splice a chunk from another corpus file
            guard let other = corpus.randomElement(using: &rng), let s = chunkSpans(other).randomElement(using: &rng),
                  let at = spans.randomElement(using: &rng)?.0 else { continue }
            b.insert(contentsOf: other[s.0..<(s.0 + 12 + s.1)], at: at)
        }
    }
    return b
}

func input(seed: UInt64, iteration: Int, corpus: [[UInt8]]) -> [UInt8] {
    var rng = SplitMix64(state: seed ^ UInt64(iteration) &* 0x2545_F491_4F6C_DD1D)
    return mutate(corpus.randomElement(using: &rng)!, corpus: corpus, rng: &rng)
}

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "png" else {
    print("usage: codec-fuzz png <corpus-dir> [iterations] [seed] | png <corpus-dir> --dump <seed> <iteration> <out>")
    exit(2)
}
let dir = URL(fileURLWithPath: args[2])
let corpus: [[UInt8]] = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    .filter { $0.hasSuffix(".png") }
    .map { [UInt8](try Data(contentsOf: dir.appendingPathComponent($0))) }
guard !corpus.isEmpty else { print("empty corpus"); exit(2) }

var limits = DecodeLimits()
limits.maxPixels = 4 * 1024 * 1024  // keep each run fast; limits themselves are tested elsewhere

if args.count >= 7 && args[3] == "--dump" {
    let bytes = input(seed: UInt64(args[4])!, iteration: Int(args[5])!, corpus: corpus)
    try Data(bytes).write(to: URL(fileURLWithPath: args[6]))
    print("wrote \(bytes.count) bytes")
    exit(0)
}

let iterations = args.count > 3 ? Int(args[3])! : 100_000
let seed = args.count > 4 ? UInt64(args[4])! : UInt64(Date().timeIntervalSince1970)
print("codec-fuzz png: \(corpus.count) seeds, \(iterations) iterations, seed \(seed)")
// Line-buffer stdout so a crash still leaves the last "seed/iteration" line.
unsafe setvbuf(stdout, nil, _IOLBF, 0)

var outcomes: [String: Int] = [:]
let started = Date()
for it in 0..<iterations {
    // Printed before each run so that a crash leaves "seed/iteration" on stdout.
    if it % 1_000 == 0 { print("seed \(seed) iteration \(it)") }
    let bytes = input(seed: seed, iteration: it, corpus: corpus)
    do {
        _ = try PNGDecoder.decode(bytes, limits: limits)
        outcomes["decoded", default: 0] += 1
    } catch {
        outcomes[error.rule, default: 0] += 1
    }
}
let rate = Double(iterations) / Date().timeIntervalSince(started)
print("done: \(iterations) inputs, \(Int(rate.rounded()))/s, no crashes")
for (k, v) in outcomes.sorted(by: { $0.value > $1.value }).prefix(15) { print("  \(v)\t\(k)") }

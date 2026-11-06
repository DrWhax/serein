// codec-fuzz: deterministic, structure-aware mutation fuzzer for SignalCodecs.
//
// Stopgap until libFuzzer is available (Xcode's toolchain lacks the fuzzer
// runtime; the swift.org toolchain has it). Run under AddressSanitizer:
//
//   swift run -c release -Xswiftc -sanitize=address codec-fuzz <target> <corpus-dir> [iterations] [seed]
//   swift run ... codec-fuzz <target> <corpus-dir> --dump <seed> <iteration> <out-file>   # reproduce a crash
//
// Targets: png (PngSuite); mp4, h264, aac, mp3 (Media.swift; seeds from
// Tests/DifferentialTests/Resources/{MP4,H264,AAC,MP3}).
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
let targets = ["png", "mp4", "h264", "aac", "mp3"]
guard args.count >= 3, targets.contains(args[1]) else {
    print("usage: codec-fuzz <\(targets.joined(separator: "|"))> <corpus-dir> [iterations] [seed] | <target> <corpus-dir> --dump <seed> <iteration> <out>")
    exit(2)
}
let target = args[1]
let dir = URL(fileURLWithPath: args[2])

var limits = DecodeLimits()
limits.maxPixels = 4 * 1024 * 1024  // keep each run fast; limits themselves are tested elsewhere

/// One target: how many seeds, an input for (seed, iteration) as bytes (for --dump), and a run.
struct Target {
    var seeds: Int
    var input: (UInt64, Int) -> [UInt8]
    var run: (UInt64, Int) -> String
}

func rng(_ seed: UInt64, _ it: Int) -> SplitMix64 { SplitMix64(state: seed ^ UInt64(it) &* 0x2545_F491_4F6C_DD1D) }

func unitTarget(_ seeds: [UnitSeed], run: @escaping ([[UInt8]], UnitSeed.Context) -> String) -> Target {
    func units(_ s: UInt64, _ it: Int) -> ([[UInt8]], UnitSeed.Context) {
        var r = rng(s, it)
        let seed = seeds.randomElement(using: &r)!
        return (MediaFuzz.mutateUnits(seed, corpus: seeds, rng: &r), seed.context)
    }
    // --dump writes the units length-prefixed (u32be) for inspection.
    return Target(seeds: seeds.count, input: { s, it in
        units(s, it).0.flatMap { u in [UInt8(u.count >> 24 & 0xFF), UInt8(u.count >> 16 & 0xFF), UInt8(u.count >> 8 & 0xFF), UInt8(u.count & 0xFF)] + u }
    }, run: { s, it in let (u, c) = units(s, it); return run(u, c) })
}

let t: Target
switch target {
case "png":
    let corpus: [[UInt8]] = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        .filter { $0.hasSuffix(".png") }
        .map { [UInt8](try Data(contentsOf: dir.appendingPathComponent($0))) }
    t = Target(seeds: corpus.count, input: { input(seed: $0, iteration: $1, corpus: corpus) }, run: { s, it in
        do { _ = try PNGDecoder.decode(input(seed: s, iteration: it, corpus: corpus), limits: limits); return "decoded" } catch { return (error as? ParseFailure)?.rule ?? "\(error)" }
    })
case "mp4":
    let corpus = MediaFuzz.files(dir, [".mp4", ".m4a"])
    func mp4Input(_ s: UInt64, _ it: Int) -> [UInt8] {
        var r = rng(s, it)
        return MediaFuzz.mutateMP4(corpus.randomElement(using: &r)!, corpus: corpus, rng: &r)
    }
    t = Target(seeds: corpus.count, input: mp4Input, run: { MediaFuzz.runMP4(mp4Input($0, $1)) })
case "h264":
    t = unitTarget(MediaFuzz.h264Seeds(MediaFuzz.files(dir, [".mp4"])), run: MediaFuzz.runH264)
case "aac":
    t = unitTarget(MediaFuzz.aacSeeds(MediaFuzz.files(dir, [".aac", ".m4a"])), run: MediaFuzz.runAAC)
default:
    t = unitTarget(MediaFuzz.mp3Seeds(MediaFuzz.files(dir, [".mp3"])), run: MediaFuzz.runMP3)
}
guard t.seeds > 0 else { print("empty corpus"); exit(2) }

if args.count >= 7 && args[3] == "--dump" {
    let bytes = t.input(UInt64(args[4])!, Int(args[5])!)
    try Data(bytes).write(to: URL(fileURLWithPath: args[6]))
    print("wrote \(bytes.count) bytes")
    exit(0)
}

let iterations = args.count > 3 ? Int(args[3])! : 100_000
let seed = args.count > 4 ? UInt64(args[4])! : UInt64(Date().timeIntervalSince1970)
print("codec-fuzz \(target): \(t.seeds) seeds, \(iterations) iterations, seed \(seed)")
// Line-buffer stdout so a crash still leaves the last "seed/iteration" line.
unsafe setvbuf(stdout, nil, _IOLBF, 0)

var outcomes: [String: Int] = [:]
let started = Date()
let every = target == "png" ? 1_000 : 50
for it in 0..<iterations {
    // Printed before each run so that a crash leaves "seed/iteration" on stdout.
    if it % every == 0 { print("seed \(seed) iteration \(it)") }
    outcomes[t.run(seed, it), default: 0] += 1
}
let rate = Double(iterations) / Date().timeIntervalSince(started)
print("done: \(iterations) inputs, \(Int(rate.rounded()))/s, no crashes")
for (k, v) in outcomes.sorted(by: { $0.value > $1.value }).prefix(15) { print("  \(v)\t\(k)") }

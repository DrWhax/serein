// Phase 5 targets: MP4 (demux + every sample decoded), H.264 (NAL payloads of the seeds'
// samples), AAC (access units from ADTS and MP4), MP3 (frame bodies). Each seed is parsed
// once into units, and mutations act on the units (bit flips and interesting bytes inside
// a unit, truncation, duplicate / delete / swap / splice of whole units), so inputs keep
// their framing and reach the decoders' inner loops. Seeds come from
// Tests/DifferentialTests/Resources (files ≤ 200 KB).

import AudioAAC
import AudioMP3
import CodecCore
import ContainerMP4
import Foundation
import VideoH264

/// A seed as units, plus what decoding needs besides them.
struct UnitSeed {
    var units: [[UInt8]]
    var context: Context
    enum Context {
        case h264(sps: [[UInt8]], pps: [[UInt8]], nalLengthSize: Int)
        case aac(AACConfig)
        case none
    }
}

enum MediaFuzz {
    static let maxUnits = 40

    static func mutateUnits(_ seed: UnitSeed, corpus: [UnitSeed], rng: inout SplitMix64) -> [[UInt8]] {
        var u = Array(seed.units.prefix(maxUnits))
        for _ in 0 ..< Int.random(in: 1 ... 6, using: &rng) {
            guard !u.isEmpty else { break }
            let i = Int.random(in: 0 ..< u.count, using: &rng)
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0, 1, 2:   // bit flip inside a unit (past its first byte: the NAL header / frame tag)
                guard u[i].count > 1 else { continue }
                let j = Int.random(in: 1 ..< u[i].count, using: &rng)
                u[i][j] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
            case 3, 4:
                guard u[i].count > 1 else { continue }
                u[i][Int.random(in: 1 ..< u[i].count, using: &rng)] = interesting.randomElement(using: &rng)!
            case 5:         // truncate a unit
                guard u[i].count > 1 else { continue }
                u[i].removeLast(Int.random(in: 1 ... max(1, u[i].count / 2), using: &rng))
            case 6:         // duplicate
                u.insert(u[i], at: Int.random(in: 0 ... u.count, using: &rng))
            case 7:         // delete
                u.remove(at: i)
            case 8:         // swap
                u.swapAt(i, Int.random(in: 0 ..< u.count, using: &rng))
            default:        // splice a unit from another seed
                if let other = corpus.randomElement(using: &rng), let x = other.units.randomElement(using: &rng) { u[i] = x }
            }
        }
        return u
    }

    // MARK: seeds

    static func files(_ dir: URL, _ exts: [String]) -> [[UInt8]] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().filter { n in exts.contains { n.hasSuffix($0) } }
            .compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }.filter { $0.count <= 200_000 }.map { [UInt8]($0) }
    }

    static func h264Seeds(_ files: [[UInt8]]) -> [UnitSeed] {
        files.compactMap { b in
            guard let f = try? MP4Demuxer.parse(b), let t = f.videoTracks.first, case .avc(_, _, _, let c)? = t.sampleEntries.first else { return nil }
            let samples = t.samples.prefix(maxUnits).compactMap { s -> [UInt8]? in s.offset >= 0 && s.offset + s.size <= b.count ? Array(b[s.offset ..< s.offset + s.size]) : nil }
            return UnitSeed(units: samples, context: .h264(sps: c.sequenceParameterSets.map { $0.copyBytes() }, pps: c.pictureParameterSets.map { $0.copyBytes() },
                                                           nalLengthSize: c.nalLengthSize))
        }
    }

    static func aacSeeds(_ files: [[UInt8]]) -> [UnitSeed] {
        files.compactMap { b in
            if b.count > 8, Array(b[4 ..< 8]) == Array("ftyp".utf8) {
                guard let f = try? MP4Demuxer.parse(b), let t = f.audioTracks.first, case .aac(_, _, let e)? = t.sampleEntries.first,
                      let config = try? AACConfig.parse(e.audioSpecificConfig) else { return nil }
                let units = t.samples.prefix(maxUnits).compactMap { s -> [UInt8]? in s.offset >= 0 && s.offset + s.size <= b.count ? Array(b[s.offset ..< s.offset + s.size]) : nil }
                return UnitSeed(units: units, context: .aac(config))
            }
            guard let frames = try? ADTS.frames(b), let first = frames.first else { return nil }
            return UnitSeed(units: frames.prefix(maxUnits).map { $0.payload.copyBytes() }, context: .aac(first.config))
        }
    }

    static func mp3Seeds(_ files: [[UInt8]]) -> [UnitSeed] {
        files.compactMap { b in
            guard let s = try? MP3Stream.parse(b) else { return nil }
            return UnitSeed(units: s.frames.prefix(maxUnits).map { $0.bytes.copyBytes() }, context: .none)
        }
    }

    // MARK: harnesses (each returns an outcome label; only traps are failures)

    static func runH264(_ units: [[UInt8]], _ ctx: UnitSeed.Context) -> String {
        guard case .h264(let sps, let pps, let n) = ctx else { return "no context" }
        var limits = H264Decoder.Limits()
        limits.threads = 2
        guard var d = try? H264Decoder(sequenceParameterSets: sps, pictureParameterSets: pps, limits: limits) else { return "parameter sets" }
        var frames = 0
        for u in units { frames += d.decode(sample: ByteSlice(u), nalLengthSize: n, pts: nil).count }
        frames += d.flush().count
        return d.errorCount > 0 ? "concealed" : frames > 0 ? "decoded" : "no frames"
    }

    static func runAAC(_ units: [[UInt8]], _ ctx: UnitSeed.Context) -> String {
        guard case .aac(let config) = ctx else { return "no context" }
        var d = AACDecoder(config: config)
        var ok = 0, failed = "decoded"
        for u in units {
            do { _ = try d.decode(ByteSlice(u)); ok += 1 } catch { failed = error.rule }
        }
        return ok == units.count ? "decoded" : failed
    }

    /// MP3: the frames concatenated back into a stream, parsed and decoded.
    static func runMP3(_ units: [[UInt8]], _ ctx: UnitSeed.Context) -> String {
        let bytes = units.flatMap { $0 }
        do {
            let s = try MP3Stream.parse(bytes)
            var d = MP3Decoder(for: s)
            var failed = "decoded"
            for f in s.frames { do { _ = try d.decode(f, channels: s.channels) } catch { failed = error.rule } }
            return failed
        } catch {
            return error.rule
        }
    }

    /// MP4: box-aware byte mutations of the whole file, then the demuxer and every sample.
    static func runMP4(_ b: [UInt8]) -> String {
        let f: MP4File
        do { f = try MP4Demuxer.parse(b) } catch { return error.rule }
        var label = "demuxed"
        for t in f.tracks {
            switch t.sampleEntries.first {
            case .avc(_, _, _, let c)?:
                label = runH264(t.samples.prefix(maxUnits).compactMap { s in s.offset >= 0 && s.size >= 0 && s.offset + s.size <= b.count ? Array(b[s.offset ..< s.offset + s.size]) : nil },
                                .h264(sps: c.sequenceParameterSets.map { $0.copyBytes() }, pps: c.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: c.nalLengthSize))
            case .aac(_, _, let e)?:
                guard let config = try? AACConfig.parse(e.audioSpecificConfig) else { label = "asc"; continue }
                label = runAAC(t.samples.prefix(maxUnits).compactMap { s in s.offset >= 0 && s.size >= 0 && s.offset + s.size <= b.count ? Array(b[s.offset ..< s.offset + s.size]) : nil }, .aac(config))
            default:
                break
            }
        }
        return label
    }

    /// Box spans (start, size) of a (possibly malformed) ISOBMFF buffer, descending into the
    /// usual containers.
    static func boxSpans(_ b: [UInt8], _ range: Range<Int>, depth: Int = 0, into out: inout [(Int, Int)]) {
        var i = range.lowerBound
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta"]
        while i + 8 <= range.upperBound {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard n >= 8, i + n <= range.upperBound else { break }
            out.append((i, n))
            let type = String(decoding: b[i + 4 ..< i + 8], as: UTF8.self)
            if containers.contains(type), depth < 8 { boxSpans(b, i + 8 ..< i + n, depth: depth + 1, into: &out) }
            if type == "stsd", n > 16, depth < 8 { boxSpans(b, i + 16 ..< i + n, depth: depth + 1, into: &out) }
            i += n
        }
    }

    static func mutateMP4(_ input: [UInt8], corpus: [[UInt8]], rng: inout SplitMix64) -> [UInt8] {
        var b = input
        for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
            var spans: [(Int, Int)] = []
            boxSpans(b, 0 ..< b.count, into: &spans)
            guard !b.isEmpty else { break }
            switch Int.random(in: 0 ..< 8, using: &rng) {
            case 0, 1, 2:   // a byte inside a box body (sample tables, configs, sample data)
                guard let s = spans.filter({ $0.1 > 8 }).randomElement(using: &rng) else { continue }
                let j = s.0 + 8 + Int.random(in: 0 ..< s.1 - 8, using: &rng)
                if Bool.random(using: &rng) { b[j] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng) } else { b[j] = interesting.randomElement(using: &rng)! }
            case 3:         // a box size or type
                guard let s = spans.randomElement(using: &rng) else { continue }
                b[s.0 + Int.random(in: 0 ..< 8, using: &rng)] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
            case 4:         // a 32-bit field inside a box set to an interesting value
                guard let s = spans.filter({ $0.1 >= 16 }).randomElement(using: &rng) else { continue }
                let j = s.0 + 8 + 4 * Int.random(in: 0 ..< (s.1 - 8) / 4, using: &rng)
                let v: UInt32 = [0, 1, 0x7FFF_FFFF, 0xFFFF_FFFF, 0x8000_0000, UInt32(b.count), 0xFFFF].randomElement(using: &rng)!
                for k in 0 ..< 4 { b[j + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
            case 5:         // truncate
                b.removeLast(Int.random(in: 1 ... max(1, b.count / 4), using: &rng))
            case 6:         // delete a box (its parents' sizes now lie)
                guard let s = spans.randomElement(using: &rng) else { continue }
                b.removeSubrange(s.0 ..< s.0 + s.1)
            default:        // splice a box from another seed
                guard let other = corpus.randomElement(using: &rng), let s = spans.randomElement(using: &rng) else { continue }
                var os: [(Int, Int)] = []
                boxSpans(other, 0 ..< other.count, into: &os)
                guard let o = os.filter({ $0.1 < 20_000 }).randomElement(using: &rng) else { continue }
                b.insert(contentsOf: other[o.0 ..< o.0 + o.1], at: s.0)
            }
        }
        return b
    }
}

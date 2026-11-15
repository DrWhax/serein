import CodecCore
import Testing
@testable import VideoHEVC

@Suite struct HEVCSecurityTests {
    private func invalidCrop(extra: Int) throws -> [UInt8] {
        let f = try HEVCFixture("intra8")
        let unit = try HEVCNALUnit.make(try #require(f.config.sequenceParameterSets.first).copyBytes()[...])
        var r = HEVCReader(unit.rbsp)
        try r.skip(4, "vps")
        let layers = try r.u(3, "layers")
        try r.skip(1, "nesting")
        _ = try HEVCProfileTierLevel.parse(&r, maxSubLayersMinus1: layers)
        _ = try r.ue("id")
        let chroma = try r.ue("chroma")
        if chroma == 3 { try r.skip(1, "separate") }
        let width = try r.ue("width")
        _ = try r.ue("height")
        let lo = r.position
        if try r.flag("crop") { for _ in 0..<4 { _ = try r.ue("offset") } }
        let hi = r.position
        let bits = unit.rbsp.flatMap { byte in (0..<8).map { UInt32(byte >> (7 - $0) & 1) } }
        var out = MSBBitWriter()
        for b in bits[..<lo] { out.write(b, 1) }
        out.write(1 as UInt32, 1)
        func ue(_ n: Int, _ w: inout MSBBitWriter) {
            let value = UInt32(n + 1), length = 32 - UInt32(n + 1).leadingZeroBitCount
            w.write(0 as UInt32, length - 1); w.write(value, length)
        }
        // Remove the entire width. A valid SPS has a strictly positive cropped width.
        ue(width / (chroma == 1 || chroma == 2 ? 2 : 1) + extra, &out)
        for _ in 0..<3 { ue(0, &out) }
        for b in bits[hi...] { out.write(b, 1) }
        return out.finish()
    }

    @Test(arguments: [0, 1]) func conformanceWindowCannotRemoveTheWholePicture(_ extra: Int) throws {
        let rbsp = try invalidCrop(extra: extra)
        #expect(throws: ParseFailure.self) { try HEVCSPS.parse(rbsp) }
    }

    @Test func dimensionsAreCheckedBeforePictureAllocation() throws {
        let f = try HEVCFixture("intra8")
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() },
            sps: f.config.sequenceParameterSets.map { $0.copyBytes() }, pps: f.config.pictureParameterSets.map { $0.copyBytes() },
            nalLengthSize: f.config.nalLengthSize, expectedDimensions: (1, 1), pictureLimit: 1)
        _ = d.decode(sample: ByteSlice(try #require(f.samples().first)), pts: 0)
        _ = d.flush()
        #expect(d.errorCount > 0)
        #expect(d.nextPictureId == 0, "picture was allocated before the container constraint")
    }

    @Test func stillImageCannotAllocateMultiplePictures() throws {
        let f = try HEVCFixture("ipb8")
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() },
            sps: f.config.sequenceParameterSets.map { $0.copyBytes() }, pps: f.config.pictureParameterSets.map { $0.copyBytes() },
            nalLengthSize: f.config.nalLengthSize, pictureLimit: 1)
        for sample in f.samples().prefix(2) { _ = d.decode(sample: ByteSlice(sample), pts: 0) }
        _ = d.flush()
        #expect(d.picturesStarted == 1)
        #expect(d.errorCount > 0)
    }

    /// A stream that redefines its SPS (another picture size) in the middle of a coded video
    /// sequence decodes on (with errors) and does not trap. Smoke test: motion compensation
    /// clamps into each reference by its own size, but these spliced slices mostly fail to
    /// parse before predicting across sizes.
    @Test(arguments: [false, true]) func midStreamPictureSizeChangeIsContained(_ withPPS: Bool) throws {
        let f = try HEVCFixture("ipb8"), other = try HEVCFixture("intra8")
        let n = f.config.nalLengthSize
        func prefixed(_ nal: [UInt8]) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: nal.count >> (8 * $0)) } + nal }
        var inject = other.config.sequenceParameterSets.flatMap { prefixed($0.copyBytes()) }
        if withPPS { inject += other.config.pictureParameterSets.flatMap { prefixed($0.copyBytes()) } }
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: n)
        var frames = 0
        for (i, s) in f.samples().enumerated() { frames += d.decode(sample: ByteSlice(i == 4 ? inject + s : s), pts: Int64(i)).count }
        frames += d.flush().count
        #expect(frames > 0)
    }

    /// Corrupted wavefront pictures decode or fail as errors, and never hang: rows read their
    /// entry points at once, a row that fails (or ends before its CTB row does) releases the
    /// rows waiting below it, and the stream goes on with the next picture. Slice data gets
    /// random bytes, its second half zeroed, or the slice header (entry points) scrambled.
    @Test(arguments: ["wpp_slices8", "vt10", "ipb8"]) func corruptWavefrontRowsFailCleanly(_ name: String) throws {
        let f = try HEVCFixture(name)
        let samples = f.samples(), lengthSize = f.config.nalLengthSize
        var seed: UInt64 = 0x5EED
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: seed >> 33)
        }
        var errors = 0, frames = 0, wavefront = 0
        for round in 0..<60 {
            let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                    pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: lengthSize)
            for (i, s) in samples.enumerated() {
                var m = s
                var at = 0
                while at + lengthSize <= m.count {
                    let n = m[at ..< at + lengthSize].reduce(0) { $0 << 8 | Int($1) }
                    let start = at + lengthSize, end = min(m.count, start + n)
                    at = end
                    guard end - start > 8, (m[start] >> 1) & 0x3F < 32, (i + round) % 3 != 0 else { continue }
                    let body = (start + 3) ..< end
                    switch round % 3 {
                    case 0: for _ in 0..<4 { m[body.lowerBound + next() % body.count] = UInt8(truncatingIfNeeded: next()) }
                    case 1: for k in (body.lowerBound + body.count / 2) ..< end { m[k] = 0 }
                    default: for k in body.prefix(6) { m[k] = UInt8(truncatingIfNeeded: next()) }
                    }
                }
                frames += d.decode(sample: ByteSlice(m), pts: Int64(i)).count
            }
            frames += d.flush().count
            errors += d.errorCount
            wavefront += d.wavefrontSegments
        }
        #expect(errors > 0 && frames > 0 && wavefront > 0, "\(name): \(errors) errors, \(frames) frames, \(wavefront) wavefront segments")
    }

    /// intra8's SPS with its picture size replaced.
    private func sps(width: Int, height: Int) throws -> [UInt8] {
        let f = try HEVCFixture("intra8")
        let unit = try HEVCNALUnit.make(try #require(f.config.sequenceParameterSets.first).copyBytes()[...])
        var r = HEVCReader(unit.rbsp)
        try r.skip(4, "vps")
        let layers = try r.u(3, "layers")
        try r.skip(1, "nesting")
        _ = try HEVCProfileTierLevel.parse(&r, maxSubLayersMinus1: layers)
        _ = try r.ue("id")
        if try r.ue("chroma") == 3 { try r.skip(1, "separate") }
        let lo = r.position
        _ = try r.ue("width")
        _ = try r.ue("height")
        let hi = r.position
        let bits = unit.rbsp.flatMap { byte in (0..<8).map { UInt32(byte >> (7 - $0) & 1) } }
        var out = MSBBitWriter()
        for b in bits[..<lo] { out.write(b, 1) }
        Self.ue(width, &out)
        Self.ue(height, &out)
        for b in bits[hi...] { out.write(b, 1) }
        return out.finish()
    }

    private static func ue(_ n: Int, _ w: inout MSBBitWriter) {
        let value = UInt32(n + 1), length = 32 - UInt32(n + 1).leadingZeroBitCount
        w.write(0 as UInt32, length - 1)
        w.write(value, length)
    }

    /// A PPS for `s` with every tool off and `cols` × `rows` uniformly spaced tiles.
    private func pps(for s: HEVCSPS, cols: Int, rows: Int) -> [UInt8] {
        var w = MSBBitWriter()
        func bit(_ b: Bool) { w.write(b ? 1 : 0 as UInt32, 1) }
        Self.ue(0, &w); Self.ue(s.id, &w)
        bit(false); bit(false); w.write(0 as UInt32, 3); bit(false); bit(false)   // dependent slices … cabac_init_present
        Self.ue(0, &w); Self.ue(0, &w); Self.ue(0, &w)                           // ref idx defaults, init_qp_minus26 (se 0)
        bit(false); bit(false); bit(false)                                      // constrained intra, transform skip, cu_qp_delta
        Self.ue(0, &w); Self.ue(0, &w)                                          // cb, cr QP offsets (se 0)
        bit(false); bit(false); bit(false); bit(false)                          // slice chroma offsets, weighted (bi)pred, bypass
        bit(true); bit(false)                                                   // tiles, no wavefront
        Self.ue(cols - 1, &w); Self.ue(rows - 1, &w); bit(true); bit(true)      // uniform spacing, filter across tiles
        bit(true); bit(false); bit(false); bit(false)                           // across slices, deblocking control, scaling list, list modification
        Self.ue(0, &w); bit(false); bit(false)                                  // parallel merge level, header extension, PPS extension
        bit(true)                                                               // rbsp_stop_one_bit
        return w.finish()
    }

    /// Level 6.2's limits (Table A.8): MaxLumaPs 35 651 584 samples (8192 x 4352), at most 20
    /// tile columns and 22 tile rows. Beyond them a picture is rejected before any allocation.
    @Test func levelLimitsAreEnforced() throws {
        #expect(try HEVCSPS.parse(try sps(width: 8192, height: 4352)).height == 4352)
        #expect(throws: ParseFailure.self) { try HEVCSPS.parse(try sps(width: 8192, height: 4360)) }
        #expect(throws: ParseFailure.self) { try HEVCSPS.parse(try sps(width: 8192, height: 8192)) }
        let s = try HEVCSPS.parse(try sps(width: 1408, height: 1472))   // 22 x 23 CTBs of 64
        let p = try HEVCPPS.parse(pps(for: s, cols: 20, rows: 22), sps: [s.id: s])
        #expect(p.tileColumnWidths.count == 20 && p.tileRowHeights.count == 22)
        #expect(throws: ParseFailure.self) { try HEVCPPS.parse(pps(for: s, cols: 21, rows: 1), sps: [s.id: s]) }
        #expect(throws: ParseFailure.self) { try HEVCPPS.parse(pps(for: s, cols: 1, rows: 23), sps: [s.id: s]) }
    }

    /// A picture's later slice segment sent again over the CTBs it already decoded, once or
    /// past level 6.2's 600 segments per picture: every copy is rejected before it touches the
    /// picture (its work would otherwise be added to the picture's, and its slice index once
    /// overflowed 16 bits), so the stream decodes exactly as before, an error per copy.
    @Test(arguments: [1, 700]) func repeatedSliceSegmentsAreRejected(_ copies: Int) throws {
        let f = try HEVCFixture("wpp_slices8")
        let n = f.config.nalLengthSize
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: n)
        var frames: [HEVCFrame] = []
        for (i, sample) in f.samples().enumerated() {
            // The sample's NAL units (length prefix included); the copies go after its second
            // slice segment.
            var units: [[UInt8]] = []
            var at = 0
            while at + n <= sample.count {
                let len = sample[at ..< at + n].reduce(0) { $0 << 8 | Int($1) }
                units.append(Array(sample[at ..< min(sample.count, at + n + len)]))
                at += n + len
            }
            let vcl = units.indices.filter { (units[$0][n] >> 1) & 0x3F < 32 }
            var out = sample
            if i == 3 {
                let second = try #require(vcl.dropFirst().first)
                out = units[...second].flatMap { $0 } + Array(repeating: units[second], count: copies).flatMap { $0 } + units[(second + 1)...].flatMap { $0 }
            }
            frames += d.decode(sample: ByteSlice(out), pts: Int64(i))
        }
        frames += d.flush()
        #expect(d.errorCount == copies)
        let want = try f.expectedMD5s()
        #expect(frames.count == want.count)
        for (k, (frame, md)) in zip(frames, want).enumerated() { #expect(md5(frame) == md, "frame \(k)") }
    }

    /// Without budget for parsing rows or tiles in parallel (each in a picture of its own),
    /// their segments parse serially into the picture, bit-exact.
    @Test(arguments: ["wpp_slices8", "kvz_tiles"]) func serialFallbackIsBitExact(_ name: String) throws {
        let f = try HEVCFixture(name)
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: f.config.nalLengthSize)
        d.parallelStateBudget = 0
        var frames: [HEVCFrame] = []
        for (i, s) in f.samples().enumerated() { frames += d.decode(sample: ByteSlice(s), pts: Int64(i)) }
        frames += d.flush()
        #expect(d.errorCount == 0 && d.wavefrontSegments == 0 && d.tileParallelSegments == 0)
        let want = try f.expectedMD5s()
        #expect(frames.count == want.count)
        for (k, (frame, md)) in zip(frames, want).enumerated() { #expect(md5(frame) == md, "frame \(k)") }
    }
}

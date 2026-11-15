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
}

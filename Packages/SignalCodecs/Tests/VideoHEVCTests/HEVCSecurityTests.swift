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
}

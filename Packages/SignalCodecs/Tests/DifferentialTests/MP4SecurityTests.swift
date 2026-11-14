import CodecCore
import Testing
@testable import ContainerMP4

@Suite struct MP4SecurityTests {
    private func word(_ x: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: x >> 24), UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)]
    }
    private func box(_ kind: String, _ words: [UInt32]) -> Box {
        Box(type: FourCC(kind), offset: 0, body: ByteSlice([0, 0, 0, 0] + words.flatMap(word)))
    }
    private func samples(perChunk: UInt32 = 1, timed: UInt32 = 1, composition: UInt32? = nil) throws -> [MP4Sample] {
        var tables = [box("stsz", [1, 1]), box("stco", [1, 0]), box("stsc", [1, 1, perChunk, 1]), box("stts", [1, timed, 1])]
        if let composition { tables.append(box("ctts", [1, composition, 0])) }
        var total = 0
        return try MP4Demuxer.sampleTable(tables, stbl: box("stbl", []), fileSize: 1, limits: MP4Limits(), totalSamples: &total)
    }
    @Test func validSingleSample() throws { #expect(try samples(composition: 1).count == 1) }
    @Test func oversizedTimingRunIsRejectedBeforeIteration() {
        #expect(throws: ParseFailure.self) { try samples(timed: 100_000) }
    }
    @Test func oversizedCompositionRunIsRejectedBeforeIteration() {
        #expect(throws: ParseFailure.self) { try samples(composition: 100_000) }
    }
    @Test func oversizedChunkRunIsRejectedBeforeIteration() {
        #expect(throws: ParseFailure.self) { try samples(perChunk: 100_000) }
    }
    @Test func incompleteCompositionTableIsRejected() {
        #expect(throws: ParseFailure.self) { try samples(composition: 0) }
    }
}

@Suite struct HEIFExtentSecurityTests {
    @Test func zeroWidthExtentFieldsCannotMultiplyTheAllocationBudget() throws {
        // Two items, each declaring three extents whose offset and length fields occupy zero
        // bytes. Per-item limits alone let a tiny iloc allocate millions of slices.
        let body = ByteSlice([0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 3, 0, 2, 0, 0, 0, 3])
        let box = Box(type: FourCC("iloc"), offset: 0, body: body)
        var limits = HEIFLimits(); limits.maxExtentsPerItem = 3; limits.maxExtents = 4
        #expect(throws: ParseFailure.self) { try HEIFParser.parseIloc(box, file: ByteSlice([1]), idat: nil, limits: limits) }
        limits.maxExtents = 6
        let valid = try HEIFParser.parseIloc(box, file: ByteSlice([1]), idat: nil, limits: limits)
        #expect(valid.map { $0.1.count } == [3, 3])
    }
}

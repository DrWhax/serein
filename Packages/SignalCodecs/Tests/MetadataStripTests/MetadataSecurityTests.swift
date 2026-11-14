import Testing
@testable import MetadataStrip

@Suite struct MetadataSecurityTests {
    @Test func removedOffsetsMatchBoundarySemantics() {
        let map = MP4Strip.RemovedOffsets([2..<5, 8..<12])
        #expect(map.shift(0) == 0)
        #expect(map.shift(4) == 4)
        #expect(map.shift(5) == 2)
        #expect(map.shift(11) == 8)
        #expect(map.shift(12) == 5)
        #expect(map.shift(UInt64.max) == UInt64.max - 7)
    }
    @Test func manyRemovedRangesAndOffsets() {
        let map = MP4Strip.RemovedOffsets((0..<100_000).map { ($0 * 16)..<($0 * 16 + 8) })
        for i in 1...100_000 { #expect(map.shift(UInt64(i * 16)) == UInt64(i * 8)) }
    }
}

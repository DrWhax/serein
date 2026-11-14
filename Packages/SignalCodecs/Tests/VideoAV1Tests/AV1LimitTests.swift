import CodecCore
import Foundation
import Testing
@testable import VideoAV1

struct AV1LimitTests {
    @Test func videoBudgetPrecedesFrameAllocation() throws {
        let url = Bundle.module.url(forResource: "basic8", withExtension: "obu", subdirectory: "Resources")!
        let bytes = ByteSlice([UInt8](try Data(contentsOf: url)))
        let valid = try AV1VideoDecoder()
        _ = valid.decode(sample: bytes, pts: 0)
        #expect(!valid.flush().isEmpty || valid.framesDecoded > 0)
        var limits = DecodeLimits()
        limits.maxPixels = 1
        let bounded = try AV1VideoDecoder(limits: limits)
        #expect(bounded.decode(sample: bytes, pts: 0).isEmpty)
        #expect(bounded.flush().isEmpty)
        #expect(bounded.framesDecoded == 0)
        #expect(bounded.errorCount == 1)
        #expect(bounded.jobs.isEmpty)
    }
}

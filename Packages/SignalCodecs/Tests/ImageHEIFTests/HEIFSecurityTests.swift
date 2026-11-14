import CodecCore
import ContainerMP4
import Testing
@testable import ImageHEIF

@Suite struct HEIFSecurityTests {
    @Test func lyingSpatialExtentIsRejectedByTheCodec() throws {
        let file = try HEIFParser.parse(try HEIFFixture.bytes("avif8.avif"))
        var item = try #require(file.items.first { $0.type == FourCC("av01") })
        item.properties = item.properties.map { essential, p in
            if case .ispe = p { return (essential, .ispe(width: 1, height: 1)) }
            return (essential, p)
        }
        do {
            _ = try HEIFDecoder.decodeCoded(item, codec: .av1, limits: .default)
            Issue.record("coded dimensions bypassed container constraint")
        } catch { #expect(String(describing: error).contains("dimensions differ")) }
    }
    @Test func extentsCannotMultiplyTheInputBudget() throws {
        let file = try HEIFParser.parse(try HEIFFixture.bytes("avif8.avif"))
        var item = try #require(file.items.first)
        item.extents = Array(repeating: ByteSlice([1, 2, 3, 4]), count: 3)
        var limits = DecodeLimits(); limits.maxInputBytes = 8
        #expect(throws: ParseFailure.self) { try HEIFDecoder.itemData(item, limits: limits) }
        item.extents.removeLast()
        #expect(try HEIFDecoder.itemData(item, limits: limits).copyBytes() == [1, 2, 3, 4, 1, 2, 3, 4])
    }
    @Test func callerPixelLimitIsCheckedBeforePayloadParsing() throws {
        let file = try HEIFParser.parse(try HEIFFixture.bytes("avif8.avif"))
        var item = try #require(file.items.first { $0.type == FourCC("av01") })
        item.extents = []
        var limits = DecodeLimits(); limits.maxPixels = 1
        do {
            _ = try HEIFDecoder.decodeCoded(item, codec: .av1, limits: limits)
            Issue.record("declared dimensions exceeded pixel budget")
        } catch {
            guard case .limitExceeded = error.reason else { Issue.record("payload was reached before the dimension limit: \(error)"); return }
        }
    }
    @Test func customDimensionLimitsCannotOverflow() {
        var limits = DecodeLimits(); limits.maxDimension = Int.max; limits.maxPixels = Int.max
        #expect(throws: ParseFailure.self) { try limits.checkDimensions(width: Int.max, height: 2, at: 0, rule: "test") }
    }
}

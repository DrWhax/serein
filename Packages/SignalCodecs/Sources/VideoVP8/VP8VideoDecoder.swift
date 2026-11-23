public import CodecCore

/// RFC 6386 picture decoder. Failed or missing pictures invalidate the reference
/// chain. Hidden pictures advance decoder state without producing display output.
public struct VP8VideoDecoder: Sendable {
    private var state = VP8PictureState()
    public init() {}

    public mutating func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> VP8Frame? {
        do throws(ParseFailure) {
            let frame = try VP8Decoder.picture(ByteSlice(bytes), limits: limits, state: &state, still: false)
            return bytes[0] & 0x10 != 0 ? frame : nil
        } catch {
            state = VP8PictureState()
            throw error
        }
    }
}

struct VP8PictureState: Sendable {
    var segment = VP8Decoder.Segment()
    var filter = VP8Decoder.Filter()
    var modes = VP8ModeProbabilities()
    var map: [UInt8] = []
    // Reference 0 denotes intra prediction. The remaining slots are last, golden and alternate.
    var references: [VP8Frame?] = [nil,nil,nil,nil]
}

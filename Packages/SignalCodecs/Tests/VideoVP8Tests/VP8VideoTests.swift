import CodecCore
import CryptoKit
import Foundation
import Testing
import VideoVP8

@Suite struct VP8VideoTests {
    /// Generated moving YUV test pattern encoded with libvpx 1.15.2. The expected SHA-256
    /// covers every visible Y, U and V sample that vpxdec --rawvideo --i420 produced.
    @Test func predictivePicturesMatchLibvpx() throws {
        let url = try #require(Bundle.module.url(forResource: "motion", withExtension: "ivf", subdirectory: "Resources"))
        var reader = ByteCursor(Array(try Data(contentsOf: url)))
        try reader.skip(32)
        var decoder = VP8VideoDecoder(), digest = SHA256()
        var pictures = 0, keyframes = 0
        while !reader.isAtEnd {
            let size = Int(try reader.u32le())
            try reader.skip(8)
            let bytes = try reader.bytes(size).copyBytes()
            if bytes.first.map({ $0 & 1 == 0 }) == true { keyframes += 1 }
            let f = try #require(try decoder.decode(bytes))
            try #require(f.width == 128 && f.height == 96)
            for (plane, stride, width, height) in [(f.y, f.yStride, 128, 96), (f.u, f.uvStride, 64, 48), (f.v, f.uvStride, 64, 48)] {
                for row in 0..<height { digest.update(data: Data(plane[(row*stride)..<(row*stride+width)])) }
            }
            pictures += 1
        }
        #expect(keyframes == 1 && pictures == 24)
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "5a6a132244bdb4d6dcd7783f23a0402b634411978c70a4161453e3929eb42301")
    }

    @Test func unchangedAndPartiallyChangedPredictivePictures() throws {
        let w = 128, h = 96
        var y = (0..<w*h).map { UInt8(($0%w + $0/w) % 190 + 16) }
        let chroma = [UInt8](repeating: 128, count: w*h/4)
        var encoder = VP8VideoEncoder(), decoder = VP8VideoDecoder()
        let keyPacket = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
        let key = try #require(keyPacket)
        let first = try #require(try decoder.decode(key))
        let stillPacket = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
        let still = try #require(stillPacket)
        let repeated = try #require(try decoder.decode(still))
        #expect(key[0] & 1 == 0 && still[0] & 1 == 1 && still.count < key.count / 4)
        #expect(first.y == repeated.y)
        for row in 32..<48 { for col in 48..<64 { y[row*w + col] = 220 } }
        let updatedPacket = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
        let updated = try #require(updatedPacket)
        let last = try #require(try decoder.decode(updated))
        #expect(updated[0] & 1 == 1 && updated.count < key.count)
        #expect(abs(Int(last.y[40*last.yStride+53]) - 220) < 5)
        for row in 0..<h {
            for col in 0..<w where !(32..<48).contains(row) || !(48..<64).contains(col) {
                try #require(last.y[row*last.yStride+col] == first.y[row*first.yStride+col])
            }
        }
    }

    @Test func oddSizedColorPlanesRoundTrip() throws {
        let w = 97, h = 63, cw = (w+1)/2, ch = (h+1)/2
        let y = (0..<w*h).map { UInt8(($0 % w)*2 + ($0/w)/2) }
        let u = (0..<cw*ch).map { UInt8(30 + ($0/cw)*4) }
        let v = (0..<cw*ch).map { UInt8(220 - ($0%cw)*2) }
        let encoded = try #require(VP8IntraEncoder.encode(width: w, height: h, y: y, u: u, v: v))
        let f = try VP8Decoder.decode(ByteSlice(encoded))
        #expect(f.width == w && f.height == h)
        for (src, dst, stride, width) in [(y,f.y,f.yStride,w),(u,f.u,f.uvStride,cw),(v,f.v,f.uvStride,cw)] {
            let sum = src.indices.reduce(0) { total,i in total + abs(Int(src[i])-Int(dst[i/width*stride+i%width])) }
            #expect(Double(sum)/Double(src.count) < 3)
        }
    }
}

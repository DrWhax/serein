import CodecCore
import CryptoKit
import Foundation
import Testing
@testable import VideoVP8

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

    /// Repeating a picture refines the reconstruction cheaply, never raising its error, and settles
    /// within a few pictures to skips only (the same decode); a partly changed picture then leaves
    /// the unchanged area exactly as it was.
    @Test func unchangedAndPartiallyChangedPredictivePictures() throws {
        let w = 128, h = 96
        var y = (0..<w*h).map { UInt8(($0%w + $0/w) % 190 + 16) }
        let chroma = [UInt8](repeating: 128, count: w*h/4)
        var encoder = VP8VideoEncoder(), decoder = VP8VideoDecoder()
        func error(_ f: VP8Frame) -> Int {
            (0..<h).reduce(0) { sum, row in sum + (0..<w).reduce(0) { $0 + abs(Int(f.y[row*f.yStride+$1]) - Int(y[row*w+$1])) } }
        }
        let keyPacket = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
        let key = try #require(keyPacket)
        let first = try decoder.decode(key)
        var previous = try #require(first), settled: VP8Frame?
        for _ in 0..<6 {
            let encoded = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
            let packet = try #require(encoded)
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            #expect(packet[0] & 1 == 1 && packet.count < key.count / 4)
            #expect(error(frame) <= error(previous))
            if frame.y == previous.y && frame.u == previous.u && frame.v == previous.v && packet.count < key.count / 16 {
                settled = frame
                break
            }
            previous = frame
        }
        let still = try #require(settled, "a repeated picture never settled")
        for row in 32..<48 { for col in 48..<64 { y[row*w + col] = 220 } }
        let updatedPacket = encoder.encode(width:w, height:h, y:y, u:chroma, v:chroma)
        let updated = try #require(updatedPacket)
        let last = try #require(try decoder.decode(updated))
        #expect(updated[0] & 1 == 1 && updated.count < key.count)
        #expect(abs(Int(last.y[40*last.yStride+53]) - 220) < 5)
        for row in 0..<h {
            for col in 0..<w where !(32..<48).contains(row) || !(48..<64).contains(col) {
                try #require(last.y[row*last.yStride+col] == still.y[row*still.yStride+col])
            }
        }
    }

    /// A textured picture panning three samples left and two up per picture, coded with searched
    /// vectors: the encoder's reconstruction must be exactly what the decoder holds every picture
    /// (no drift), libvpx must decode the stream to the same samples (digest of ffmpeg libvpx's
    /// raw I420 output), and following the motion must keep inter pictures small (coding them
    /// as intra, as the encoder once did, made them larger than the keyframe).
    @Test func motionSearchFollowsAPanWithoutDrift() throws {
        let w = 160, h = 96, cw = w/2, ch = h/2
        func texture(_ x: Int, _ y: Int) -> UInt8 { UInt8(truncatingIfNeeded: (x*x)/9 + (y*y)/7 + ((x/3) ^ (y/2))*5) }
        var encoder = VP8VideoEncoder(), decoder = VP8VideoDecoder(), digest = SHA256()
        var interBytes = 0, keyBytes = 0
        for t in 0..<10 {
            let y = (0..<(w*h)).map { texture($0 % w + 3*t, $0 / w + 2*t) }
            let u = (0..<(cw*ch)).map { UInt8(truncatingIfNeeded: 128 + Int(texture(2*($0 % cw) + 3*t, 2*($0 / cw) + 2*t)) / 8) }
            let v = [UInt8](repeating: 120, count: cw*ch)
            let encoded = encoder.encode(width: w, height: h, y: y, u: u, v: v, quantizer: 48, keyframe: t == 0)
            let packet = try #require(encoded)
            if t > 0 { interBytes += packet.count } else { keyBytes = packet.count }
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            let recon = encoder.reconstruction
            #expect(frame.y == recon[0] && frame.u == recon[1] && frame.v == recon[2], "picture \(t)")
            for (plane, stride, width, height) in [(frame.y, frame.yStride, w, h), (frame.u, frame.uvStride, cw, ch), (frame.v, frame.uvStride, cw, ch)] {
                for row in 0..<height { digest.update(data: Data(plane[(row*stride)..<(row*stride+width)])) }
            }
        }
        #expect(interBytes / 9 < keyBytes / 2, "inter \(interBytes / 9) B, key \(keyBytes) B")
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "f8efca85643a9fce67a42324758b2588f0df6bcf94780ca24434521a489bc22b")
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

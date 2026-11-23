import CryptoKit
import Foundation
import Testing
@testable import VideoVP9

struct VP9EncoderTests {
    private func samples(width: Int, height: Int, component: Int, time: Int) -> [UInt8] {
        (0..<(width*height)).map { i in
            let x = i % width, y = i / width
            return UInt8(truncatingIfNeeded: ((x + time*component)*11 + (y+component)*7) ^ ((x/8+y/8)*17))
        }
    }

    /// The native libvpx decoder also rendered these filtered sequences losslessly.
    /// Decode only the frames forwarded to a client subscribed to one spatial/temporal target.
    @Test(arguments: ["L3T3_KEY", "L2T2_KEY_SHIFT", "L2T3h", "S3T3h"])
    func selectiveForwardingPreservesPixels(mode: String) throws {
        let width = 37, height = 29, cw = (width+1)/2, ch = (height+1)/2
        var encoder = try #require(VP9ScalableEncoder(mode: mode))
        var streams = [VP9VideoDecoder](repeating: .init(), count: 9)
        for time in 0..<10 {
            let y = samples(width: width, height: height, component: 1, time: time)
            let u = samples(width: cw, height: ch, component: 2, time: time)
            let v = samples(width: cw, height: ch, component: 3, time: time)
            let result = encoder.encode(width: width, height: height, y: y, u: u, v: v, quantizer: 0, keyframe: time == 8)
            let layers = try #require(result)
            for layer in layers {
                #expect(layer.refresh == (time == 0 || time == 8))
                if let distance = layer.temporalReferenceDiff { #expect((1...4).contains(distance)) }
                if mode.hasPrefix("S") { #expect(!layer.dependsOnLower) }
                for spatial in layer.spatialID..<layers.count where !mode.hasPrefix("S") || spatial == layer.spatialID {
                    for temporal in layer.temporalID..<3 {
                        let candidate = try streams[3*spatial+temporal].decode(layer.bytes)
                        let decoded = try #require(candidate)
                        try #require(decoded.width == layer.width && decoded.height == layer.height)
                        let components = [(y,width,height,decoded.y,decoded.yStride,decoded.width,decoded.height),
                                          (u,cw,ch,decoded.u,decoded.uvStride,(decoded.width+1)/2,(decoded.height+1)/2),
                                          (v,cw,ch,decoded.v,decoded.uvStride,(decoded.width+1)/2,(decoded.height+1)/2)]
                        for (input,sw,sh,output,stride,w,h) in components {
                            let matches = (0..<h).allSatisfy { row in
                                (0..<w).allSatisfy { col in output[row*stride+col] == input[(row*sh/h)*sw+col*sw/w] }
                            }
                            try #require(matches)
                        }
                    }
                }
            }
        }
    }

    /// SHA-256 over all visible planes of eight locally encoded pictures (a rectangle moving two
    /// samples a picture, so motion is searched and coded), as libvpx decodes them (ffmpeg
    /// libvpx-vp9, raw I420), including a forced keyframe and odd chroma dimensions.
    @Test func lossyReconstructionMatchesLibvpx() throws {
        let w = 77, h = 51, cw = (w+1)/2, ch = (h+1)/2
        var encoder = VP9VideoEncoder(), decoder = VP9VideoDecoder(), digest = SHA256()
        for t in 0..<8 {
            func input(_ width: Int, _ height: Int, _ colour: UInt8) -> [UInt8] {
                (0..<(width*height)).map { i in
                    let x = i % width, y = i / width, dx = t < 2 ? 0 : t*2
                    return (x > dx+4 && x < dx+17 && y > 8 && y < 18) ? colour : UInt8(40+(x*2+y*7)%160)
                }
            }
            let bytes = encoder.encode(width: w, height: h, y: input(w,h,12), u: input(cw,ch,178),
                                       v: input(cw,ch,235), quantizer: 60, keyframe: t == 5)
            let packet = try #require(bytes)
            let output = try decoder.decode(packet)
            let frame = try #require(output)
            for (p,stride,width,height) in [(frame.y,frame.yStride,w,h),(frame.u,frame.uvStride,cw,ch),(frame.v,frame.uvStride,cw,ch)] {
                for row in 0..<height { digest.update(data: Data(p[row*stride..<(row*stride+width)])) }
            }
        }
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "2e5375d867cf4888a9ab0c6fff208ac098827dff557a6c90c689f6580b0b44d9")
    }

    /// A textured picture panning three samples left and two up per picture: the encoder's own
    /// reconstruction (what it predicts the next picture from) must be exactly what the decoder
    /// holds, every picture, and following the motion must keep inter pictures small.
    @Test func motionSearchFollowsAPanWithoutDrift() throws {
        let w = 160, h = 96, cw = w/2, ch = h/2
        func texture(_ x: Int, _ y: Int) -> UInt8 { UInt8(truncatingIfNeeded: (x*x)/9 + (y*y)/7 + ((x/3) ^ (y/2))*5) }
        var encoder = VP9VideoEncoder(), decoder = VP9VideoDecoder()
        var interBytes = 0, keyBytes = 0
        for t in 0..<10 {
            let y = (0..<(w*h)).map { texture($0 % w + 3*t, $0 / w + 2*t) }
            let u = (0..<(cw*ch)).map { UInt8(truncatingIfNeeded: 128 + Int(texture(2*($0 % cw) + 3*t, 2*($0 / cw) + 2*t)) / 8) }
            let v = [UInt8](repeating: 120, count: cw*ch)
            let encoded = encoder.encode(width: w, height: h, y: y, u: u, v: v, quantizer: 100, keyframe: t == 0)
            let packet = try #require(encoded)
            if t > 0 { interBytes += packet.count } else { keyBytes = packet.count }
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            let recon = encoder.reconstruction
            #expect(frame.y == recon[0].bytes && frame.u == recon[1].bytes && frame.v == recon[2].bytes, "picture \(t)")
        }
        // Zero-motion coding made these inter pictures larger than the keyframe (1.7x); followed,
        // the pan costs about a quarter of it.
        #expect(interBytes / 9 < keyBytes / 2, "inter \(interBytes / 9) B, key \(keyBytes) B")
    }

    /// Repeating a picture refines the reconstruction cheaply, never raising its error, and settles
    /// within a few pictures to skips only (the same decode). Quantization can otherwise cycle a
    /// block between two near-equal reconstructions, paying for a residual every picture.
    @Test func repeatedPictureSettles() throws {
        let w = 128, h = 96, chroma = [UInt8](repeating: 128, count: w*h/4)
        let y = (0..<w*h).map { UInt8(($0%w + $0/w) % 190 + 16) }
        var encoder = VP9VideoEncoder(), decoder = VP9VideoDecoder()
        func error(_ f: VP9Frame) -> Int {
            (0..<h).reduce(0) { sum, row in sum + (0..<w).reduce(0) { $0 + abs(Int(f.y[row*f.yStride+$1]) - Int(y[row*w+$1])) } }
        }
        let keyPacket = encoder.encode(width: w, height: h, y: y, u: chroma, v: chroma, quantizer: 120, keyframe: true)
        let key = try #require(keyPacket)
        let first = try decoder.decode(key)
        var previous = try #require(first), settled = false
        for _ in 0..<6 {
            let encoded = encoder.encode(width: w, height: h, y: y, u: chroma, v: chroma, quantizer: 120, keyframe: false)
            let packet = try #require(encoded)
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            #expect(packet.count < key.count / 4 && error(frame) <= error(previous))
            if frame.y == previous.y && frame.u == previous.u && frame.v == previous.v && packet.count < key.count / 16 {
                settled = true
                break
            }
            previous = frame
        }
        #expect(settled)
    }

    /// A smooth gradient (one block can code it whole) under a textured square that crosses the
    /// picture fast, reaching past its edges: large blocks, every transform size, and searches
    /// near the edge of the reference all take part.
    private static func bigBlocksPicture(_ t: Int, _ w: Int, _ h: Int) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        var seed = UInt32(truncatingIfNeeded: t &* 7919 &+ 1)
        let left = (37*t) % (w + 48) - 48, top = (23*t) % (h + 48) - 48
        func inside(_ x: Int, _ y: Int) -> Bool { x >= left && x < left+48 && y >= top && y < top+48 }
        let y = (0..<(w*h)).map { i -> UInt8 in
            let x = i % w, r = i / w
            guard inside(x, r) else { return UInt8(60 + x/4 + r/8) }
            seed = seed &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: 30 + ((x - left)*7 ^ (r - top)*5) % 160 + Int(seed >> 30))
        }
        let cw = (w+1)/2, ch = (h+1)/2
        let u = (0..<(cw*ch)).map { i in inside(2*(i % cw), 2*(i / cw)) ? UInt8(90) : UInt8(128 + (i % cw)/8) }
        let v = (0..<(cw*ch)).map { i in inside(2*(i % cw), 2*(i / cw)) ? UInt8(170) : UInt8(120) }
        return (y, u, v)
    }

    /// Blocks up to 64x64 where the picture is flat, 4x4 to 16x16 transforms, and searches near
    /// the reference's edges: the encoder's reconstruction must be the decoder's every picture,
    /// and libvpx must decode the stream to the same samples (digest of ffmpeg libvpx-vp9's I420).
    @Test func largeBlocksAndTransformsMatchTheDecoder() throws {
        let w = 200, h = 136, cw = 100, ch = 68
        var encoder = VP9VideoEncoder(), decoder = VP9VideoDecoder(), digest = SHA256()
        for t in 0..<8 {
            let p = Self.bigBlocksPicture(t, w, h)
            let encoded = encoder.encode(width: w, height: h, y: p.y, u: p.u, v: p.v, quantizer: 120, keyframe: t == 0)
            let packet = try #require(encoded)
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            let recon = encoder.reconstruction
            #expect(frame.y == recon[0].bytes && frame.u == recon[1].bytes && frame.v == recon[2].bytes, "picture \(t)")
            for (plane, stride, width, height) in [(frame.y, frame.yStride, w, h), (frame.u, frame.uvStride, cw, ch), (frame.v, frame.uvStride, cw, ch)] {
                for row in 0..<height { digest.update(data: Data(plane[(row*stride)..<(row*stride+width)])) }
            }
        }
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "fe3b872ce3737ca7ca68ce874124ebd36aa76c6025365a67c088bd8fbb1975d3")
    }

    /// A picture wide enough for two tile columns, coded in parallel: the encoder's merged
    /// reconstruction must be the decoder's every picture, and libvpx must decode the same samples.
    @Test func tileColumnsMatchTheDecoder() throws {
        let w = 576, h = 72, cw = 288, ch = 36
        var encoder = VP9VideoEncoder(), decoder = VP9VideoDecoder(), digest = SHA256()
        for t in 0..<8 {
            let p = Self.bigBlocksPicture(t, w, h)
            let encoded = encoder.encode(width: w, height: h, y: p.y, u: p.u, v: p.v, quantizer: 120, keyframe: t == 0)
            let packet = try #require(encoded)
            let decoded = try decoder.decode(packet)
            let frame = try #require(decoded)
            let recon = encoder.reconstruction
            #expect(frame.y == recon[0].bytes && frame.u == recon[1].bytes && frame.v == recon[2].bytes, "picture \(t)")
            for (plane, stride, width, height) in [(frame.y, frame.yStride, w, h), (frame.u, frame.uvStride, cw, ch), (frame.v, frame.uvStride, cw, ch)] {
                for row in 0..<height { digest.update(data: Data(plane[(row*stride)..<(row*stride+width)])) }
            }
        }
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "5966c171d8d8402862f07156be2ff25c2c09e03b74ee56b84bcbc93a35ff23a6")
    }

    @Test func rejectsUnsupportedModesAndMalformedImages() {
        for mode in ["", "L4T3", "L1T1h", "S1T2", "L1T3_KEY", "L3T3_KEY_SHIFT", "S3T3_KEY", "L3T4"] {
            #expect(VP9ScalableEncoder(mode: mode) == nil)
        }
        var encoder = VP9VideoEncoder()
        #expect(encoder.encode(width: .max, height: .max, y: [], u: [], v: []) == nil)
    }

    @Test func lossySpatialRefreshPreservesAFlatCameraImage() throws {
        let w = 640, h = 360
        var encoder = try #require(VP9ScalableEncoder(mode: "L3T3_KEY"))
        var decoder = VP9VideoDecoder()
        let uv = [UInt8](repeating: 128, count: w*h/4)
        for tick in 0..<6 {
            let y = (0..<w*h).map { ($0 % w >= w/2) == (tick < 3) ? UInt8(180) : UInt8(40) }
            let encoded = encoder.encode(width: w, height: h, y: y, u: uv, v: uv, quantizer: 72)
            let layers = try #require(encoded)
            // Like a high-resolution SFU subscriber, receive the lower spatial
            // references only on a refresh, then the selected layer's deltas.
            for layer in layers where layer.refresh || layer.spatialID == 2 {
                let output = try decoder.decode(layer.bytes)
                let frame = try #require(output)
                #expect(frame.width == layer.width && frame.height == layer.height)
                let row = frame.height/2*frame.yStride
                let contrast = Int(frame.y[row + 3*frame.width/4]) - Int(frame.y[row + frame.width/4])
                #expect(tick < 3 ? contrast > 125 : contrast < -125)
            }
        }
    }
}

import CryptoKit
import Foundation
import Testing
import VideoVP9

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

    /// SHA-256 over all visible planes of eight locally encoded pictures, decoded with
    /// vpxdec --rawvideo --i420, including a forced keyframe and odd chroma dimensions.
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
        #expect(hex == "46ec2069854cf09368e3b8670599e29ed30d9d344a601ee3729292e7113944d2")
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

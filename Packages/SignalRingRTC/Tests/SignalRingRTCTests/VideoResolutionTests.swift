import Foundation
import Testing
import VideoVP9
@testable import SwiftCalling

@Suite struct VideoResolutionTests {
    @Test func requestedCameraAndScreenCaptures() {
        func size(_ w: Int, _ h: Int, screen: Bool = false, group: Bool = false, request: UInt32? = nil, low: Bool = false) -> [Int] {
            let result = DirectCallVideo.size(width: w, height: h, bitrate: low ? 260_000 : 1_960_000,
                                              requestedHeight: request, screen: screen, group: group)
            return [result.width,result.height]
        }
        #expect(size(960,720) == [960,720])
        #expect(size(640,480,group:true) == [640,480])
        #expect(size(720,1280,group:true,request:360) == [360,640])
        #expect(size(2880,1800,screen:true) == [2880,1800])
        #expect(size(1280,720,screen:true,low:true) == [960,540])
        #expect(size(160,96,screen:true) == [160,96])
    }

    /// Group calls encode their simulcast streams in parallel: every picture must be the one
    /// encoding the streams in turn gives (each stream's encoder advances only by its own picture).
    @Test func parallelSimulcastMatchesSerialEncoding() {
        let w = 640, h = 360, bitrate = 300_000, bits = bitrate / 30
        let sizes = DirectCallVideo.streamSizes((w, h), simulcast: true)
        var parallel = [DirectCallVideo.VP8Sender](repeating: .init(), count: sizes.count), serial = parallel
        let start = ContinuousClock.now
        for t in 0..<5 {
            var bytes = [UInt8](repeating: 128, count: w*h + 2*(w/2)*(h/2))
            for i in 0..<(w*h) {
                let x = i % w + 3*t, y = i / w + 2*t
                bytes[i] = UInt8(truncatingIfNeeded: x*x/97 + y*3 + ((x/16) ^ (y/16))*9)
            }
            let frame = DirectCallVideo.Frame(width: w, height: h, format: 0, bytes: bytes, revision: UInt64(t),
                                              captured: start + .milliseconds(33*t))
            let layers = DirectCallVideo.encodeSimulcast(&parallel, frame, sizes: sizes, bitrate: bitrate, bits: bits, key: t == 0,
                                                         streamsBefore: t == 0 ? 0 : sizes.count)
            // Each stream's share, as encodeSimulcast gives it.
            let weights = sizes.map { pow(Double($0.width * $0.height), 0.75) }, sum = weights.reduce(0, +)
            var expected = [[UInt8]]()
            for (index, size) in sizes.enumerated() {
                guard let picture = serial[index].encode(frame, target: size, index: index, bitrate: bitrate,
                                                         bits: Int(Double(bits) * weights[index] / sum), key: t == 0, screen: false) else { break }
                expected.append(picture.bytes)
            }
            #expect(expected.count == sizes.count && layers.map(\.bytes) == expected, "picture \(t)")
            #expect(layers.map(\.stream) == Array(0..<sizes.count))
            // The bits as sent drive each stream's quantizer: the same in both.
            for (index, layer) in layers.enumerated() {
                parallel[index].sent(bits: layer.bytes.count * 8)
                serial[index].sent(bits: layer.bytes.count * 8)
            }
        }
    }

    @Test func independentStreamsRespectSourceResolution() {
        func heights(_ w: Int,_ h: Int) -> [Int] { DirectCallVideo.streamSizes((w,h),simulcast:true).map(\.height) }
        #expect(heights(1280,720) == [180,360,720])
        #expect(heights(640,480) == [180,360,480])
        #expect(heights(192,128) == [128])
        #expect(heights(640,360) == [180,360])
    }

    @Test func detailedVP9LayersFitTogetherAndPreserveTemporalReferences() throws {
        let width = 960, height = 540
        let target = (width: width, height: height)
        let bitrate = 500_000
        let configuration = try #require(GroupVideoConfiguration(camera: "L3T3_KEY", screen: "L3T3_KEY", maximumBitrate: nil))
        var sender = DirectCallVideo.VP9Sender()
        var decoder = VP9VideoDecoder()
        let start = ContinuousClock.now
        var pixels = detailedTestScreen(width: width, height: height, inverted: false)

        func encode(_ data: [UInt8], refresh: Bool, time: ContinuousClock.Instant) throws -> (frames: [VP9EncodedLayer], mode: String) {
            let frame = DirectCallVideo.Frame(width: width, height: height, format: 0, bytes: data, revision: 1, captured: time)
            let result = sender.encode(frame, target: target, bitrate: bitrate, bits: bitrate / 30, key: refresh, group: configuration, screen: true)
            return try #require(result)
        }
        func display(_ layers: [VP9EncodedLayer]) throws -> VP9Frame {
            var shown: VP9Frame?
            for layer in layers { shown = try decoder.decode(layer.bytes) }
            return try #require(shown)
        }

        let first = try encode(pixels, refresh: true, time: start)
        #expect(first.frames.allSatisfy { $0.refresh })
        #expect(first.frames.reduce(0) { $0 + $1.bytes.count } <= bitrate / 8)
        let picture = try display(first.frames)
        #expect(first.mode == configuration.mode(screenSharing: true, width: picture.width, height: picture.height))
        #expect(picture.y[(picture.height/2)*picture.yStride + picture.width/4] < 120)

        // Change a patch in the displayed image. Decode only the accepted initial
        // access point and the next delta, including any inter-layer references.
        for row in (height*3/8)..<(height*5/8) {
            for col in (width/8)..<(width*3/8) { pixels[row*width+col] = 225 }
        }
        let next = try encode(pixels, refresh: false, time: start + .milliseconds(200))
        #expect(next.mode == first.mode)
        #expect(next.frames.allSatisfy { !$0.refresh })
        #expect(next.frames.first?.temporalReferenceDiff == 1)
        let changed = try display(next.frames)
        #expect(changed.width == picture.width && changed.height == picture.height)
        #expect(changed.y[(changed.height/2)*changed.yStride + changed.width/4] > 180)
    }
}

/// Detailed SDR screen with a detectable brightness change across its center.
/// Each luma sample contains deterministic fine texture.
func detailedTestScreen(width: Int, height: Int, inverted: Bool) -> [UInt8] {
    var frame = [UInt8](repeating: 128, count: width*height*3/2)
    var random: UInt64 = 57
    for row in 0..<height {
        for col in 0..<width {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let bright = (col >= width/2) != inverted
            frame[row*width+col] = UInt8((bright ? 161 : 16) + Int(random >> 58))
        }
    }
    return frame
}

import CodecCore
import Foundation
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

/// Animated GIFs and APNGs built byte by byte (four colours; a frame may cover part of the canvas).
enum AnimationBuilder {
    /// Palette: transparent, red, green, blue.
    static let palette: [[UInt8]] = [[0, 0, 0], [255, 0, 0], [0, 255, 0], [0, 0, 255]]
    static let rgba: [[UInt8]] = [[0, 0, 0, 0], [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]

    struct Frame {
        var x = 0, y = 0, width: Int, height: Int
        var index: UInt8
        var delayCentiseconds = 10
    }

    /// `loop`: the NETSCAPE2.0 count as stored (nil: no extension).
    static func gif(width: Int, height: Int, loop: Int?, _ frames: [Frame]) -> Data {
        var b = Array("GIF89a".utf8)
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        u16(width); u16(height)
        b += [0xF1, 0, 0]   // global table of 4 colours
        for c in palette { b += c }
        if let loop { b += [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1]; u16(loop); b += [0] }
        for f in frames {
            // Graphic control: restore nothing, index 0 transparent.
            b += [0x21, 0xF9, 4, 0x01]; u16(f.delayCentiseconds); b += [0, 0]
            b += [0x2C]; u16(f.x); u16(f.y); u16(f.width); u16(f.height); b += [0]
            // LZW, minimum code size 2: a clear code before every pixel keeps codes 3 bits wide.
            var bits: [Bool] = []
            func code(_ c: Int) { for i in 0..<3 { bits.append(c >> i & 1 == 1) } }
            for _ in 0..<(f.width * f.height) { code(4); code(Int(f.index)) }
            code(5)
            var data: [UInt8] = []
            for i in stride(from: 0, to: bits.count, by: 8) {
                var v: UInt8 = 0
                for j in 0..<8 where i + j < bits.count && bits[i + j] { v |= 1 << j }
                data.append(v)
            }
            b += [2]
            for i in stride(from: 0, to: data.count, by: 255) {
                let chunk = data[i..<min(i + 255, data.count)]
                b += [UInt8(chunk.count)] + chunk
            }
            b += [0]
        }
        b += [0x3B]
        return Data(b)
    }

    /// Full-canvas frames; the default image is the first. `delay`: milliseconds (num/1000).
    static func apng(width: Int, height: Int, plays: Int, colours: [UInt8], delay: Int = 100) -> Data {
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ data: [UInt8]) {
            let body = Array(type.utf8) + data
            out += be32(data.count) + body + be32(Int(crc32(body)))
        }
        func zlib(_ raw: [UInt8]) -> [UInt8] {
            var z: [UInt8] = [0x78, 0x01]
            var i = 0
            repeat {
                let n = min(65535, raw.count - i)
                z += [i + n == raw.count ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8 & 0xFF)] + raw[i..<i + n]
                i += n
            } while i < raw.count
            var a: UInt32 = 1, s: UInt32 = 0
            for v in raw { a = (a + UInt32(v)) % 65521; s = (s + a) % 65521 }
            return z + be32(Int(s << 16 | a))
        }
        func pixels(_ c: UInt8) -> [UInt8] {
            var raw: [UInt8] = []
            for _ in 0..<height { raw.append(0); for _ in 0..<width { raw += rgba[Int(c)] } }
            return raw
        }
        chunk("IHDR", be32(width) + be32(height) + [8, 6, 0, 0, 0])
        chunk("acTL", be32(colours.count) + be32(plays))
        var seq = 0
        for (i, c) in colours.enumerated() {
            chunk("fcTL", be32(seq) + be32(width) + be32(height) + be32(0) + be32(0) + be16(delay) + be16(1000) + [0, 0])
            seq += 1
            if i == 0 { chunk("IDAT", zlib(pixels(c))) } else { chunk("fdAT", be32(seq) + zlib(pixels(c))); seq += 1 }
        }
        chunk("IEND", [])
        return Data(out)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
}

@Suite struct DisplayAnimationTests {
    func frame(_ a: DisplayAnimation, _ i: Int) -> [UInt8] {
        let n = a.width * a.height * 4
        return Array(a.frames[a.frames.startIndex + i * n ..< a.frames.startIndex + (i + 1) * n])
    }

    @Test func gifFramesAreCompositedInOrder() async throws {
        // A red 8×8 canvas, then a green 4×4 patch at (4, 4), then a blue one at (0, 0).
        let gif = AnimationBuilder.gif(width: 8, height: 8, loop: 0, [
            .init(width: 8, height: 8, index: 1, delayCentiseconds: 5),
            .init(x: 4, y: 4, width: 4, height: 4, index: 2, delayCentiseconds: 0),
            .init(width: 4, height: 4, index: 3, delayCentiseconds: 20),
        ])
        let a = try await MediaDecoder().displayAnimation(gif, maxDimension: 64).validated(maxDimension: 64)
        #expect(a.width == 8 && a.height == 8 && a.frameCount == 3 && a.plays == 0)
        // As encoded; the player clamps short durations.
        #expect(a.delays == [50, 0, 200])
        func px(_ f: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(f[(y * 8 + x) * 4 ..< (y * 8 + x) * 4 + 4]) }
        let f0 = frame(a, 0), f1 = frame(a, 1), f2 = frame(a, 2)
        #expect(px(f0, 6, 6) == [255, 0, 0, 255])
        #expect(px(f1, 6, 6) == [0, 255, 0, 255] && px(f1, 1, 1) == [255, 0, 0, 255])
        #expect(px(f2, 1, 1) == [0, 0, 255, 255] && px(f2, 6, 6) == [0, 255, 0, 255])
    }

    /// Chromium's counts: GIF's stored n repeats n times after the first play; none plays once.
    @Test func gifPlayCounts() async throws {
        let frames: [AnimationBuilder.Frame] = [.init(width: 2, height: 2, index: 1), .init(width: 2, height: 2, index: 2)]
        for (loop, plays) in [(nil, 1), (0, 0), (1, 2), (2, 3)] as [(Int?, Int)] {
            let a = try await MediaDecoder().displayAnimation(AnimationBuilder.gif(width: 2, height: 2, loop: loop, frames), maxDimension: 8)
            #expect(a.plays == plays, "loop \(String(describing: loop))")
        }
    }

    @Test func apngPlaysAsStored() async throws {
        let png = AnimationBuilder.apng(width: 4, height: 4, plays: 3, colours: [1, 2, 3], delay: 40)
        let a = try await MediaDecoder().displayAnimation(png, maxDimension: 64).validated(maxDimension: 64)
        #expect(a.frameCount == 3 && a.plays == 3 && a.delays == [40, 40, 40])
        #expect(Array(frame(a, 2).prefix(4)) == [0, 0, 255, 255])
    }

    @Test func framesAreFittedToMaxDimension() async throws {
        let png = AnimationBuilder.apng(width: 40, height: 20, plays: 0, colours: [1, 2])
        let a = try await MediaDecoder().displayAnimation(png, maxDimension: 10).validated(maxDimension: 10)
        #expect(a.width == 10 && a.height == 5 && a.originalWidth == 40 && a.originalHeight == 20 && a.frames.count == 10 * 5 * 4 * 2)
    }

    /// 300 × 300 × 4 × 150 frames is 51.5 MiB: scaled down until the frames fit 48 MiB.
    @Test func longAnimationsAreScaledIntoTheBudget() async throws {
        var frames: [AnimationBuilder.Frame] = [.init(width: 300, height: 300, index: 1)]
        for i in 1..<150 { frames.append(.init(x: i, y: i, width: 1, height: 1, index: UInt8(2 + i % 2))) }
        let a = try await MediaDecoder().displayAnimation(AnimationBuilder.gif(width: 300, height: 300, loop: 0, frames), maxDimension: 300)
            .validated(maxDimension: 300)
        #expect(a.frameCount == 150 && a.width == a.height && a.width < 300 && a.width >= 280)
        #expect(a.frames.count <= DisplayAnimation.maxBytes)
    }

    @Test func stillImagesHaveOneFrame() async throws {
        let a = try await MediaDecoder().displayAnimation(MediaDecoderTests.sample(), maxDimension: 150).validated(maxDimension: 150)
        #expect(a.frameCount == 1 && a.width == 150 && a.height == 100 && a.plays == 1)
        let one = AnimationBuilder.gif(width: 2, height: 2, loop: 0, [.init(width: 2, height: 2, index: 1)])
        #expect(try await MediaDecoder().displayAnimation(one, maxDimension: 8).frameCount == 1)
        await #expect(throws: MediaProcessingError.self) { try await MediaDecoder().displayAnimation(Data([1, 2, 3]), maxDimension: 8) }
        await #expect(throws: MediaProcessingError.self) { try await MediaDecoder().displayAnimation(MediaDecoderTests.sample(), maxDimension: 0) }
    }

    /// What the app accepts from the service.
    @Test func validationBoundsTheReply() {
        func a(_ w: Int, _ h: Int, frames: Int, bytes: Int? = nil, delays: [Int]? = nil, plays: Int = 0) -> DisplayAnimation {
            DisplayAnimation(width: w, height: h, frames: Data(count: bytes ?? w * h * 4 * frames), delays: delays ?? Array(repeating: 100, count: frames),
                             plays: plays, originalWidth: w, originalHeight: h)
        }
        #expect((try? a(4, 4, frames: 2).validated(maxDimension: 4)) != nil)
        #expect((try? a(5, 4, frames: 2).validated(maxDimension: 4)) == nil)
        #expect((try? a(4, 4, frames: 2, bytes: 4 * 4 * 4 * 2 - 1).validated(maxDimension: 4)) == nil)
        #expect((try? a(4, 4, frames: 0).validated(maxDimension: 4)) == nil)
        #expect((try? a(1, 1, frames: DisplayAnimation.maxFrames + 1).validated(maxDimension: 4)) == nil)
        #expect((try? a(4, 4, frames: 2, delays: [100, -1]).validated(maxDimension: 4)) == nil)
        #expect((try? a(4, 4, frames: 2, plays: -1).validated(maxDimension: 4)) == nil)
        // More than the budget only for a still frame.
        #expect((try? a(4096, 4096, frames: 1).validated(maxDimension: 4096)) != nil)
        #expect((try? a(2048, 2048, frames: 4).validated(maxDimension: 4096)) == nil)
    }

    @Test func roundTripsThroughXPC() async throws {
        let listener = XPCServer.anonymous(requirement: nil, MediaXPCHandler())
        let client = MediaXPCClient(timeout: .seconds(10), decoder: .endpoint(listener.endpoint))
        let png = AnimationBuilder.apng(width: 4, height: 4, plays: 0, colours: [1, 2, 3], delay: 30)
        let a = try await client.displayAnimation(png, maxDimension: 16)
        #expect(a.frameCount == 3 && a.delays == [30, 30, 30] && a.plays == 0 && Array(a.frames.prefix(4)) == [255, 0, 0, 255])
        listener.cancel()
    }
}

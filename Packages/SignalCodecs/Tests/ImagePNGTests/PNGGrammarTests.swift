import Testing
@testable import CodecCore
@testable import ImagePNG

let red: [UInt8] = [255, 0, 0, 255]
let blue: [UInt8] = [0, 0, 255, 255]
let halfGreen: [UInt8] = [0, 255, 0, 128]
let clear: [UInt8] = [0, 0, 0, 0]

func simple(_ edit: (inout PNGBuilder) -> Void = { _ in }) -> [UInt8] {
    var b = PNGBuilder()
    b.ihdr(2, 2)
    edit(&b)
    b.idat(2, 2) { _, _ in red }
    b.iend()
    return b.bytes
}

@Suite struct PNGGrammarPolicyTests {
    @Test func minimalImageDecodes() throws {
        let img = try PNGDecoder.decode(simple()).stillImage
        #expect(img.width == 2 && img.height == 2)
        #expect(img.rgba == red + red + red + red)
    }

    @Test func unknownAncillaryChunkIsSkippedEvenWithBadCRC() throws {
        let bytes = simple { $0.chunk("zzZz", [1, 2, 3], corruptCRC: true) }
        #expect(try PNGDecoder.decode(bytes).stillImage.width == 2)
    }

    @Test func unknownCriticalChunkIsRejected() {
        let bytes = simple { $0.chunk("ZZZZ", [1, 2, 3]) }
        expectFailure(bytes, contains: "unknown critical chunk")
    }

    @Test func badCRCOnCriticalChunkIsRejected() {
        var b = PNGBuilder()
        b.ihdr(2, 2)
        b.chunk("IDAT", PNGBuilder.zlibStored(PNGBuilder.rgbaScanlines(2, 2) { _, _ in red }), corruptCRC: true)
        b.iend()
        do {
            _ = try PNGDecoder.decode(b.bytes)
            Issue.record("expected failure")
        } catch {
            guard case .checksum = error.reason else { Issue.record("\(error)"); return }
        }
    }

    @Test func nonConsecutiveIDATIsRejected() {
        var b = PNGBuilder()
        b.ihdr(1, 2)
        let z = PNGBuilder.zlibStored(PNGBuilder.rgbaScanlines(1, 2) { _, _ in red })
        b.chunk("IDAT", Array(z[0..<5]))
        b.chunk("teXt", Array("a\0b".utf8))
        b.chunk("IDAT", Array(z[5...]))
        b.iend()
        expectFailure(b.bytes, contains: "non-consecutive IDAT")
    }

    @Test func iendWithPayloadIsRejected() {
        var b = PNGBuilder()
        b.ihdr(1, 1)
        b.idat(1, 1) { _, _ in red }
        b.chunk("IEND", [0])
        expectFailure(b.bytes, contains: "IEND")
    }

    @Test func bytesAfterIENDAreIgnored() throws {
        #expect(try PNGDecoder.decode(simple() + [1, 2, 3, 4]).stillImage.width == 2)
    }

    @Test func malformedTRNSIsIgnoredNotFatal() throws {
        // tRNS is forbidden with an alpha channel: ignored per policy.
        let img = try PNGDecoder.decode(simple { $0.chunk("tRNS", [0, 0]) }).stillImage
        #expect(img.rgba[3] == 255)
    }

    @Test func dimensionLimitIsEnforcedBeforeDecoding() {
        var b = PNGBuilder()
        b.ihdr(20_000, 20_000)
        b.iend()
        do {
            _ = try PNGDecoder.decode(b.bytes)
            Issue.record("expected failure")
        } catch {
            guard case .limitExceeded = error.reason else { Issue.record("\(error)"); return }
        }
    }

    @Test func tooMuchImageDataIsRejected() {
        var b = PNGBuilder()
        b.ihdr(1, 1)
        b.idat(1, 2) { _, _ in red }  // two rows for a one-row image
        b.iend()
        #expect(throws: ParseFailure.self) { try PNGDecoder.decode(b.bytes) }
    }

    @Test func invalidFilterTypeIsRejected() {
        var b = PNGBuilder()
        b.ihdr(1, 1)
        b.chunk("IDAT", PNGBuilder.zlibStored([5] + red))
        b.iend()
        expectFailure(b.bytes, contains: "filter type 5")
    }

    @Test(arguments: [(UInt8(3), UInt8(16)), (2, 4), (6, 1), (4, 2), (7, 8)])
    func invalidColourTypeDepthCombinationsAreRejected(colorType: UInt8, depth: UInt8) {
        var b = PNGBuilder()
        b.ihdr(1, 1, depth: depth, colorType: colorType)
        b.iend()
        #expect(throws: ParseFailure.self) { try PNGDecoder.decode(b.bytes) }
    }

    @Test func failuresCarryOffsetAndPath() {
        var b = PNGBuilder()
        b.chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 9])  // interlace = 9
        b.iend()
        do {
            _ = try PNGDecoder.decode(b.bytes)
            Issue.record("expected failure")
        } catch {
            #expect(error.rule == "IHDR.interlace")
            #expect(error.path == ["IHDR"])
            #expect(error.offset == 8 + 8 + 12)
        }
    }

    func expectFailure(_ bytes: [UInt8], contains text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try PNGDecoder.decode(bytes)
            Issue.record("expected failure containing \(text)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.description.contains(text), "\(error)", sourceLocation: sourceLocation)
        }
    }
}

@Suite struct APNGTests {
    /// 4x4 red default image = frame 0; frame 1 is 2x2 half-green blended over at (1,1).
    func twoFrame(blend: UInt8, dispose0: UInt8 = 0, seqOffset: UInt32 = 0) -> [UInt8] {
        var b = PNGBuilder()
        b.ihdr(4, 4)
        b.actl(frames: 2, plays: 3)
        b.fctl(seq: 0, w: 4, h: 4, delay: (1, 10), dispose: dispose0)
        b.idat(4, 4) { _, _ in red }
        b.fctl(seq: 1 + seqOffset, w: 2, h: 2, x: 1, y: 1, delay: (50, 0), blend: blend)
        b.fdat(seq: 2 + seqOffset, 2, 2) { _, _ in halfGreen }
        b.iend()
        return b.bytes
    }

    @Test func framesDelaysAndLoopCount() throws {
        guard case .animated(let anim, let poster) = try PNGDecoder.decode(twoFrame(blend: 0)) else {
            Issue.record("expected animation"); return
        }
        #expect(anim.frames.count == 2)
        #expect(anim.loopCount == 3)
        #expect(anim.frames[0].delayMilliseconds == 100)
        #expect(anim.frames[1].delayMilliseconds == 500)  // den 0 means 1/100 s
        #expect(poster.rgba == anim.frames[0].image.rgba)
        // blend_op SOURCE replaces the region, alpha included.
        let p = anim.frames[1].image.pixel(x: 1, y: 1)
        #expect([p.r, p.g, p.b, p.a] == halfGreen)
        let q = anim.frames[1].image.pixel(x: 0, y: 0)
        #expect([q.r, q.g, q.b, q.a] == red)
    }

    @Test func blendOverCompositesWithStraightAlpha() throws {
        guard case .animated(let anim, _) = try PNGDecoder.decode(twoFrame(blend: 1)) else {
            Issue.record("expected animation"); return
        }
        let p = anim.frames[1].image.pixel(x: 2, y: 2)
        // 50% green over opaque red ≈ (127, 128, 0, 255)
        #expect(abs(Int(p.r) - 127) <= 1 && abs(Int(p.g) - 128) <= 1 && p.b == 0 && p.a == 255)
    }

    @Test func disposeBackgroundClearsRegionBeforeNextFrame() throws {
        guard case .animated(let anim, _) = try PNGDecoder.decode(twoFrame(blend: 1, dispose0: 1)) else {
            Issue.record("expected animation"); return
        }
        // Frame 0 disposed to transparent, so frame 1 is half-green over nothing.
        let corner = anim.frames[1].image.pixel(x: 0, y: 0)
        #expect([corner.r, corner.g, corner.b, corner.a] == clear)
        let mid = anim.frames[1].image.pixel(x: 1, y: 1)
        #expect([mid.r, mid.g, mid.b, mid.a] == halfGreen)
    }

    @Test func sequenceErrorDropsAnimationButKeepsImage() throws {
        let file = try PNGGrammar.file(ByteSlice(twoFrame(blend: 0, seqOffset: 5)))
        #expect(file.animation == nil)
        #expect(file.animationRejection?.contains("sequence") == true)
        guard case .still(let img) = try PNGDecoder.decode(file) else { Issue.record("expected still"); return }
        #expect(img.rgba[0..<4] == red[...])
    }

    @Test func frameCountMismatchDropsAnimation() throws {
        var b = PNGBuilder()
        b.ihdr(2, 2)
        b.actl(frames: 3, plays: 0)
        b.fctl(seq: 0, w: 2, h: 2)
        b.idat(2, 2) { _, _ in red }
        b.iend()
        let file = try PNGGrammar.file(ByteSlice(b.bytes))
        #expect(file.animation == nil)
        #expect(file.animationRejection?.contains("3 frames") == true)
    }

    @Test func frameOutsideCanvasDropsAnimation() throws {
        var b = PNGBuilder()
        b.ihdr(2, 2)
        b.actl(frames: 2, plays: 0)
        b.fctl(seq: 0, w: 2, h: 2)
        b.idat(2, 2) { _, _ in red }
        b.fctl(seq: 1, w: 2, h: 2, x: 1, y: 1)
        b.fdat(seq: 2, 2, 2) { _, _ in blue }
        b.iend()
        let file = try PNGGrammar.file(ByteSlice(b.bytes))
        #expect(file.animation == nil)
        #expect(file.animationRejection == "malformed fcTL")
    }

    @Test func defaultImageNotPartOfAnimation() throws {
        var b = PNGBuilder()
        b.ihdr(2, 2)
        b.actl(frames: 1, plays: 0)
        b.idat(2, 2) { _, _ in red }
        b.fctl(seq: 0, w: 2, h: 2)
        b.fdat(seq: 1, 2, 2) { _, _ in blue }
        b.iend()
        guard case .animated(let anim, let poster) = try PNGDecoder.decode(b.bytes) else {
            Issue.record("expected animation"); return
        }
        #expect(anim.frames.count == 1)
        #expect(poster.rgba[0..<4] == red[...])
        #expect(anim.frames[0].image.rgba[0..<4] == blue[...])
    }

    @Test func animationOverMemoryBudgetFallsBackToStill() throws {
        var limits = DecodeLimits()
        limits.maxAnimationBytes = 4 * 4 * 4  // one frame's worth
        guard case .still = try PNGDecoder.decode(twoFrame(blend: 0), limits: limits) else {
            Issue.record("expected still fallback"); return
        }
    }
}

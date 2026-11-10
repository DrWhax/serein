// The XPC wire format (MediaXPCInterface/Wire.swift): every request and reply type survives
// a round trip, and a hostile peer's bytes (truncated, extended, mutated, oversized, mistyped)
// are refused with an error, never a crash or an allocation larger than the message.

import Foundation
@testable import MediaXPCInterface
import Testing

@Suite struct WireTests {
    static let id = UUID(uuidString: "6F1C3A2E-9B5D-4E7F-8A1B-2C3D4E5F6A7B")!

    static let requests: [MediaRequest] = [
        .stickerImage(Data([1, 2, 3])), .displayImage(Data([4]), maxDimension: 800), .imageInfo(Data()),
        .thumbnail(Data([5, 6]), size: 150), .scaleForSending(Data([7]), contentType: "image/jpeg", level: .two),
        .stripMetadata(Data([8]), contentType: "image/png"), .convertHEIC(Data([9])), .audioSummary(Data([10])),
        .decodeAudio(Data([11]), startFrame: 4800, maxFrames: 96000), .startVoiceNote(sampleRate: 48000),
        .appendVoiceNote(id, samples: [0, -1, 0.5, .infinity, -.zero]), .finishVoiceNote(id), .cancelVoiceNote(id),
        .videoInfo(Data([12])), .posterFrame(Data([13])), .openVideo(Data([14])), .videoFrames(id, count: 8),
        .seekVideo(id, seconds: 12.5), .closeVideo(id),
    ]

    static let gifs = PaginatedGifResults(next: 25, gifs: [
        GifResult(id: "abc", title: "Cat", description: "",
                  previewMedia: GifMedia(url: URL(string: "https://media1.giphy.com/media/abc/200w.mp4")!, width: 200, height: 150),
                  attachmentMedia: GifMedia(url: URL(string: "https://media2.giphy.com/media/abc/giphy.mp4")!, width: 480, height: 360)),
    ])

    static let preview = FetchedLinkPreview(title: "Signal », ünïcode 🙂", description: nil, date: 1_700_000_000_000,
                                            imageHref: "https://signal.org/a.png", image: FetchedImage(data: Data([0x89, 0x50]), contentType: "image/png"))

    func roundTrip<T: Codable>(_ v: T) throws -> T {
        try Wire.decode(T.self, try Wire.encode(v), maxBytes: 1 << 20)
    }

    @Test func requestsRoundTrip() throws {
        for request in Self.requests {
            let back = try roundTrip(request)
            #expect(try Wire.encode(back) == (try Wire.encode(request)), "\(request)")
        }
        let samples: [Float] = [1, 2, 3]
        guard case .appendVoiceNote(let id, let s) = try roundTrip(MediaRequest.appendVoiceNote(Self.id, samples: samples)) else {
            Issue.record("wrong case"); return
        }
        #expect(id == Self.id && s == samples)
    }

    @Test func repliesRoundTrip() throws {
        #expect(try roundTrip(Self.gifs) == Self.gifs)
        #expect(try roundTrip(Optional(Self.preview)) == Self.preview)
        #expect(try roundTrip(FetchedLinkPreview?.none) == nil)
        #expect(try roundTrip(LinkPreviewHTML(title: "t", description: "d", imageHref: nil, rawDate: "2024-01-01")).rawDate == "2024-01-01")
        #expect(try roundTrip(ImageInfo(width: 3, height: 4, blurHash: String(repeating: "A", count: 28), isAnimated: true)).isAnimated)
        #expect(try roundTrip(DisplayImage(width: 1, height: 1, rgba: Data([1, 2, 3, 4]), originalWidth: 9, originalHeight: 9)).rgba == Data([1, 2, 3, 4]))
        #expect(try roundTrip(StickerImage(data: Data(), contentType: "", refusal: .tooLarge)).refusal == .tooLarge)
        #expect(try roundTrip(OpenedVideo(session: Self.id, info: VideoInfo(width: 2, height: 2, rotation: 90, duration: 1.5, hasAudio: true, goodForStories: false))).session == Self.id)
        #expect(try roundTrip(Data([0, 255])) == Data([0, 255]))
        #expect(try roundTrip(MediaEmpty()) is MediaEmpty)
        if case .file(let url) = try roundTrip(GifSearchRequest.file(Self.gifs.gifs[0].attachmentMedia.url)) {
            #expect(url == Self.gifs.gifs[0].attachmentMedia.url)
        } else { Issue.record("wrong case") }
        if case .html(_, let charset) = try roundTrip(LinkPreviewParserRequest.html(Data([1]), httpCharset: nil)) { #expect(charset == nil) }
    }

    @Test func refusesAnythingButTheExactMessage() throws {
        let wire = try Wire.encode(Self.gifs)
        #expect(throws: (any Error).self) { try Wire.decode(PaginatedGifResults.self, wire + Data([0]), maxBytes: 1 << 20) }
        #expect(throws: (any Error).self) { try Wire.decode(PaginatedGifResults.self, wire, maxBytes: wire.count - 1) }
        var magic = wire
        magic[magic.startIndex] ^= 1
        #expect(throws: (any Error).self) { try Wire.decode(PaginatedGifResults.self, magic, maxBytes: 1 << 20) }
        // Every truncation fails.
        for n in 0..<wire.count {
            #expect(throws: (any Error).self) { try Wire.decode(PaginatedGifResults.self, wire.prefix(n), maxBytes: 1 << 20) }
        }
        // Another type's message is not this one.
        #expect(throws: (any Error).self) { try Wire.decode(FetchedLinkPreview?.self, wire, maxBytes: 1 << 20) }
        #expect(throws: (any Error).self) { try Wire.decode(MediaRequest.self, try Wire.encode(GifSearchRequest.trending(limit: 1, offset: nil)), maxBytes: 1 << 20) }
    }

    /// Hand-built hostile messages for `struct { var a: Int8?; var s: String }`-like shapes.
    struct Small: Codable, Equatable {
        var flag: Bool
        var n: Int8
        var s: String
        var list: [Int]
    }

    func message(_ body: [UInt8]) -> Data { Data(Wire.magic + body) }
    func tag(_ s: String) -> [UInt8] { [UInt8(s.utf8.count)] + Array(s.utf8) }
    func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    func i64(_ v: Int64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: v) >> (8 * $0)) } }

    @Test func refusesHostileFields() throws {
        let good = tag("flag") + [1] + tag("n") + i64(-5) + tag("s") + u32(2) + Array("hi".utf8) + tag("list") + u32(1) + i64(7)
        #expect(try Wire.decode(Small.self, message(good), maxBytes: 1 << 10) == Small(flag: true, n: -5, s: "hi", list: [7]))
        #expect(try Wire.encode(Small(flag: true, n: -5, s: "hi", list: [7])) == message(good))
        let hostile: [[UInt8]] = [
            tag("flag") + [2] + tag("n") + i64(0) + tag("s") + u32(0) + tag("list") + u32(0),                         // bool 2
            tag("flag") + [0] + tag("n") + i64(300) + tag("s") + u32(0) + tag("list") + u32(0),                       // Int8 overflow
            tag("flag") + [0] + tag("n") + i64(0) + tag("s") + u32(2) + [0xC3, 0x28] + tag("list") + u32(0),          // bad UTF-8
            tag("flag") + [0] + tag("n") + i64(0) + tag("s") + u32(0xFFFF_FFFF) + tag("list") + u32(0),               // length > rest
            tag("flag") + [0] + tag("n") + i64(0) + tag("s") + u32(0) + tag("list") + u32(0xFFFF_FFFF),               // count > rest
            tag("flag") + [0] + tag("m") + i64(0) + tag("s") + u32(0) + tag("list") + u32(0),                         // wrong tag
            tag("n") + i64(0) + tag("flag") + [0] + tag("s") + u32(0) + tag("list") + u32(0),                         // wrong order
            tag("flag") + [0] + tag("n") + i64(0) + tag("s") + u32(0) + tag("list") + u32(2) + i64(1),                // fewer elements
        ]
        for h in hostile {
            #expect(throws: (any Error).self) { try Wire.decode(Small.self, message(h), maxBytes: 1 << 10) }
        }
    }

    @Test func refusesHostileEnums() throws {
        // An unknown case, a case with the wrong fields, two cases.
        #expect(throws: (any Error).self) { try Wire.decode(LinkPreviewFetchRequest.self, message(tag("delete") + tag("_0") + u32(0)), maxBytes: 1 << 10) }
        #expect(throws: (any Error).self) { try Wire.decode(LinkPreviewFetchRequest.self, message(tag("page") + tag("_1") + u32(0)), maxBytes: 1 << 10) }
        let two = tag("page") + tag("_0") + u32(0) + tag("image") + tag("_0") + u32(0)
        #expect(throws: (any Error).self) { try Wire.decode(LinkPreviewFetchRequest.self, message(two), maxBytes: 1 << 10) }
        #expect(throws: (any Error).self) { try Wire.decode(FetchedImage?.self, message([2]), maxBytes: 1 << 10) }
    }

    /// A malicious helper flipping bytes: every mutation decodes or throws (deterministic, small).
    @Test func survivesMutatedReplies() throws {
        let wires = [try Wire.encode(Self.gifs), try Wire.encode(Optional(Self.preview)), try Wire.encode(Self.requests[4])]
        var rng = SplitMix(seed: 0x5EE1)
        for wire in wires {
            for _ in 0..<2000 {
                var m = wire
                for _ in 0..<Int(rng.next() % 4 + 1) {
                    let i = m.startIndex + Int(rng.next() % UInt64(m.count))
                    m[i] = UInt8(truncatingIfNeeded: rng.next())
                }
                _ = try? Wire.decode(PaginatedGifResults.self, m, maxBytes: 1 << 20)
                _ = try? Wire.decode(FetchedLinkPreview?.self, m, maxBytes: 1 << 20)
                _ = try? Wire.decode(MediaRequest.self, m, maxBytes: 1 << 20)
            }
        }
    }

    @Test func repliesAreCappedPerRequest() {
        #expect(MediaRequest.displayImage(Data(), maxDimension: 100).maxReplyBytes < 1 << 20)
        #expect(MediaRequest.displayImage(Data(), maxDimension: .max).maxReplyBytes <= 4096 * 4096 * 4 + (64 << 10))
        #expect(MediaRequest.imageInfo(Data()).maxReplyBytes == 64 << 10)
        #expect(MediaRequest.decodeAudio(Data(), startFrame: 0, maxFrames: .max).maxReplyBytes <= AudioLimits.maxChunkFrames * 8 + (64 << 10))
        #expect(MediaRequest.decodeAudio(Data(), startFrame: 0, maxFrames: -1).maxReplyBytes == 64 << 10)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

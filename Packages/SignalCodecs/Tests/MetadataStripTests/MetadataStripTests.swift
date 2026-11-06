// MetadataStrip on fixtures carrying phone/camera metadata (Tools/gen-metadata-fixtures.sh:
// GPS, make/model, dates, XMP, IPTC, comments — every text value contains "Secret"): the
// stripped file has none of it and shows the same picture.

import CodecCore
import ContainerMP4
import Foundation
import ImageGIF
import ImageJPEG
import ImagePNG
import ImageWebP
import Testing
import VideoH264
@testable import MetadataStrip

@Suite struct MetadataStripTests {
    static func fixture(_ name: String) -> [UInt8] {
        [UInt8](try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Resources/\(name)")))
    }

    static func contains(_ b: [UInt8], _ s: String) -> Bool {
        let n = Array(s.utf8)
        guard b.count >= n.count else { return false }
        for i in 0 ... b.count - n.count where b[i] == n[0] && Array(b[i ..< i + n.count]) == n { return true }
        return false
    }

    func check(_ name: String, _ kind: MetadataStrip.Kind) throws -> ([UInt8], [UInt8]) {
        let original = Self.fixture(name)
        #expect(Self.contains(original, "Secret"), "\(name) fixture has no metadata")
        let out = try MetadataStrip.strip(original, kind: kind)
        #expect(!Self.contains(out, "Secret"), "\(name): metadata left")
        // Idempotent.
        #expect(try MetadataStrip.strip(out, kind: kind) == out || kind == .jpeg)
        return (original, out)
    }

    @Test func jpeg() throws {
        let (a, b) = try check("photo.jpg", .jpeg)
        // Orientation 6 kept (the photo stays upright): the same decoded, rotated pixels.
        let da = try JPEGDecoder.decode(a), db = try JPEGDecoder.decode(b)
        #expect(da == db && da.width == 64 && da.height == 96)
        #expect(!Self.contains(b, "http://ns.adobe.com/xap") && !Self.contains(b, "Photoshop"))
        #expect(b.count < a.count)
    }

    @Test func png() throws {
        let (a, b) = try check("image.png", .png)
        #expect(try PNGDecoder.decode(a) == PNGDecoder.decode(b))
        for t in ["tEXt", "zTXt", "iTXt", "eXIf"] { #expect(!Self.contains(b, t), "\(t)") }
    }

    @Test func webp() throws {
        let (a, b) = try check("image.webp", .webp)
        #expect(try WebPDecoder.decode(a) == WebPDecoder.decode(b))
        #expect(!Self.contains(b, "EXIF") && !Self.contains(b, "XMP "))
    }

    @Test func gif() throws {
        let (a, b) = try check("anim.gif", .gif)
        let da = try GIFDecoder.decode(a), db = try GIFDecoder.decode(b)
        #expect(da == db)
        guard case .animated = db else { Issue.record("animation lost"); return }
        #expect(Self.contains(b, "NETSCAPE2.0") == Self.contains(a, "NETSCAPE2.0"))
    }

    /// Every frame decodes as before, and the times are zeroed.
    @Test(arguments: ["moov_last.mp4", "faststart.mp4", "clip.mov"])
    func video(name: String) throws {
        let (a, b) = try check(name, .isobmffVideo)
        func frames(_ bytes: [UInt8]) throws -> [[UInt8]] {
            let f = try MP4Demuxer.parse(bytes)
            let t = try #require(f.videoTracks.first)
            guard case .avc(_, _, _, let c)? = t.sampleEntries.first else { throw ParseFailure(offset: 0, rule: "avc", reason: .invalid("no avc")) }
            var d = try H264Decoder(sequenceParameterSets: c.sequenceParameterSets.map { $0.copyBytes() }, pictureParameterSets: c.pictureParameterSets.map { $0.copyBytes() })
            var out: [[UInt8]] = []
            for s in t.samples { out += d.decode(sample: ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])), nalLengthSize: c.nalLengthSize, pts: s.compositionTime).map { $0.picture.y } }
            out += d.flush().map { $0.picture.y }
            return out
        }
        let fa = try frames(a), fb = try frames(b)
        #expect(fa.count == 6 && fa == fb)
        // mvhd creation/modification times are zero.
        let top = try ISOBoxes.children(b, 0 ..< b.count, topLevel: true)
        let moov = try #require(top.first { $0.type == "moov" })
        let mvhd = try #require(try ISOBoxes.children(b, moov.bodyStart ..< moov.end, topLevel: false).first { $0.type == "mvhd" })
        #expect(b[mvhd.bodyStart + 4 ..< mvhd.bodyStart + 12].allSatisfy { $0 == 0 })
        #expect(top.allSatisfy { MP4Strip.topKept.contains($0.type) })
        #expect(!Self.contains(b, "udta") && !Self.contains(b, "©xyz") && !Self.contains(b, "com.apple.quicktime.location"))
    }

    /// The Exif and XMP items are zeroed in place; nothing else changes.
    @Test func heif() throws {
        let (a, b) = try check("photo.heic", .heif)
        #expect(a.count == b.count)
        let changed = zip(a, b).filter { $0 != $1 }.count
        #expect(changed > 0 && zip(a, b).allSatisfy { $0 == $1 || $1 == 0 })
        // The payloads (after the meta box, whose item table names the type "Exif") are gone.
        let meta = try #require(try ISOBoxes.children(b, 0 ..< b.count, topLevel: true).first { $0.type == "meta" })
        let data = Array(b[meta.end...])
        #expect(Self.contains(Array(a[meta.end...]), "Exif\0\0") && !Self.contains(data, "Exif\0\0") && !Self.contains(data, "<x:xmpmeta"))
        #expect(try ISOBoxes.children(a, 0 ..< a.count, topLevel: true).map(\.type) == ISOBoxes.children(b, 0 ..< b.count, topLevel: true).map(\.type))
    }

    @Test func malformedInputsThrow() {
        for (bytes, kind) in [([UInt8]([0xFF, 0xD8, 0xFF]), MetadataStrip.Kind.jpeg), (Array("not a png".utf8), .png), (Array("RIFF\u{FF}\u{FF}\u{FF}\u{0F}WEBP".utf8), .webp),
                              (Array("GIF89a".utf8), .gif), ([0, 0, 0, 9] + Array("ftyp".utf8), .isobmffVideo), (Array("garbage".utf8), .heif)] {
            #expect(throws: ParseFailure.self) { try MetadataStrip.strip(bytes, kind: kind) }
        }
    }
}

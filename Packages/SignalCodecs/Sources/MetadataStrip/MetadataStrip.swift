// Removes metadata from images and videos before they are sent (user decision 2026-11-05:
// "strip exif on images and videos"). Images that are re-encoded for sending carry none
// already; this covers what goes out as the original bytes (GIF, images the scaler cannot
// decode, videos). Every format is walked with bounded cursors; anything malformed throws,
// and the caller then refuses to send the file rather than send its metadata.
//
//   JPEG  keeps SOI, the tables, frames, scans and RST/EOI; APP0 only as a plain JFIF (no
//         thumbnail), APP2 only ICC_PROFILE, APP14 Adobe (the colour transform). Drops every
//         other APPn (Exif and XMP in APP1, MPF, IPTC/Photoshop in APP13, …), COM, and
//         anything after EOI (appended previews). An Exif orientation other than 1 is
//         kept as a minimal Exif block with that one tag, so the photo stays upright.
//   PNG   drops tEXt, zTXt, iTXt, eXIf and tIME, and anything after IEND.
//   WebP  drops EXIF, XMP and unknown chunks (clearing VP8X's Exif and XMP flags), and
//         anything after the RIFF.
//   GIF   drops comment and application extensions other than NETSCAPE2.0 / ANIMEXTS1.0
//         (the loop count); keeps graphic control and plain text extensions.
//   MP4 / QuickTime  drops udta, meta, uuid, free and skip boxes in the file and the movie
//         tree, top-level boxes other than the media ones, zeroes the creation and
//         modification times (mvhd, tkhd, mdhd), and moves the chunk offsets (stco, co64)
//         by the bytes removed before them.
//   HEIF / AVIF  zeroes the bytes of Exif items and of XMP (`mime` application/rdf+xml)
//         items in place (iinf + iloc), so the image's structure does not change; drops
//         top-level udta / uuid / free / skip only when they follow the data.

public import CodecCore
import ImageJPEG

public enum MetadataStrip {
    public enum Kind: Sendable, Equatable { case jpeg, png, webp, gif, isobmffVideo, heif }

    /// The stripper for a MIME type (nil: no metadata format we know; BMP and ICO have none).
    public static func kind(contentType: String) -> Kind? {
        switch contentType.lowercased() {
        case "image/jpeg", "image/jpg": .jpeg
        case "image/png", "image/apng": .png
        case "image/webp": .webp
        case "image/gif": .gif
        case "video/mp4", "video/quicktime", "video/x-m4v", "audio/mp4", "audio/x-m4a": .isobmffVideo
        case "image/heic", "image/heif", "image/avif", "image/heic-sequence", "image/heif-sequence": .heif
        default: nil
        }
    }

    public static func strip(_ bytes: [UInt8], kind: Kind) throws(ParseFailure) -> [UInt8] {
        switch kind {
        case .jpeg: try jpeg(bytes)
        case .png: try png(bytes)
        case .webp: try webp(bytes)
        case .gif: try gif(bytes)
        case .isobmffVideo: try MP4Strip.strip(bytes)
        case .heif: try HEIFStrip.strip(bytes)
        }
    }

    // MARK: JPEG

    static func jpeg(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        var c = ByteCursor(bytes)
        try c.expect([0xFF, 0xD8], "SOI")
        var out: [UInt8] = [0xFF, 0xD8]
        var orientation = 1
        var exifAt = 2   // where the orientation block goes: after SOI, or after a JFIF APP0
        while true {
            guard try c.u8("marker") == 0xFF else { throw c.fail("marker", .invalid("expected 0xFF")) }
            var m = try c.u8("marker")
            while m == 0xFF { m = try c.u8("marker") }
            switch m {
            case 0xD9:
                out += [0xFF, 0xD9]
                if orientation != 1 { out.insert(contentsOf: exifOrientationSegment(orientation), at: exifAt) }
                return out
            case 0x01, 0xD0 ... 0xD7:
                out += [0xFF, m]
            default:
                let length = Int(try c.u16be("segment.length"))
                guard length >= 2 else { throw c.fail("segment.length", .invalid("length \(length)")) }
                let body = try c.bytes(length - 2, "segment")
                switch m {
                case 0xE0:
                    var b = body.cursor()
                    if body.count >= 12, (try? b.expect(Array("JFIF".utf8) + [0], "JFIF")) != nil {
                        // version, units, densities; no thumbnail
                        let head = try b.bytes(7, "JFIF").copyBytes()
                        out += [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0] + head + [0, 0]
                        exifAt = out.count
                    }
                case 0xE1:
                    if let o = JPEGGrammar.exifOrientation(body) { orientation = o }
                case 0xE2:
                    var b = body.cursor()
                    if (try? b.expect(Array("ICC_PROFILE".utf8) + [0], "ICC")) != nil { segment(&out, m, body) }
                case 0xEE:
                    var b = body.cursor()
                    if (try? b.expect(Array("Adobe".utf8), "Adobe")) != nil { segment(&out, m, body) }
                case 0xE3 ... 0xED, 0xEF, 0xFE:
                    break
                case 0xDA:
                    segment(&out, m, body)
                    // Entropy-coded data up to the next marker that is not a stuffed 0 or RST.
                    while true {
                        let b = try c.u8("scan")
                        if b != 0xFF { out.append(b); continue }
                        var n = try c.u8("scan")
                        while n == 0xFF { n = try c.u8("scan") }
                        if n == 0x00 || (0xD0 ... 0xD7).contains(n) { out += [0xFF, n]; continue }
                        // Put the marker back: rewind by two (0xFF n).
                        c = try rewound(c, bytes, by: 2)
                        break
                    }
                default:
                    segment(&out, m, body)
                }
            }
        }
    }

    static func segment(_ out: inout [UInt8], _ m: UInt8, _ body: ByteSlice) {
        let n = body.count + 2
        out += [0xFF, m, UInt8(n >> 8), UInt8(n & 0xFF)]
        body.append(to: &out)
    }

    /// A cursor over the same bytes, `by` bytes back.
    static func rewound(_ c: ByteCursor, _ bytes: [UInt8], by: Int) throws(ParseFailure) -> ByteCursor {
        var r = ByteCursor(bytes)
        try r.skip(c.consumed - by, "rewind")
        return r
    }

    /// `Exif\0\0` + a big-endian TIFF with IFD0 holding only Orientation.
    static func exifOrientationSegment(_ o: Int) -> [UInt8] {
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8,  // MM, 42, IFD0 at 8
                             0x00, 0x01,                          // one entry
                             0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, 0x00, UInt8(o), 0, 0,  // Orientation SHORT 1
                             0, 0, 0, 0]                          // no next IFD
        let body = Array("Exif".utf8) + [0, 0] + tiff
        let n = body.count + 2
        return [0xFF, 0xE1, UInt8(n >> 8), UInt8(n & 0xFF)] + body
    }

    // MARK: PNG

    static let pngDropped: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME"]

    static func png(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        var c = ByteCursor(bytes)
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        try c.expect(sig, "PNG.signature")
        var out = sig
        while true {
            let n = Int(try c.u32be("chunk.length"))
            let type = try c.bytes(4, "chunk.type")
            let data = try c.bytes(n, "chunk.data")
            let crc = try c.bytes(4, "chunk.crc")
            let name = String(decoding: type.copyBytes(), as: UTF8.self)
            if !pngDropped.contains(name) {
                out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                type.append(to: &out)
                data.append(to: &out)
                crc.append(to: &out)
            }
            if name == "IEND" { return out }
        }
    }

    // MARK: WebP

    static let webpKept: Set<String> = ["VP8X", "VP8 ", "VP8L", "ALPH", "ANIM", "ANMF", "ICCP"]

    static func webp(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        var c = ByteCursor(bytes)
        try c.expect(Array("RIFF".utf8), "RIFF")
        let riffSize = Int(try c.u32le("RIFF.size"))
        guard riffSize >= 4, riffSize <= c.remaining else { throw c.fail("RIFF.size", .invalid("size \(riffSize)")) }
        var body = try c.bytes(riffSize, "RIFF.body").cursor()
        try body.expect(Array("WEBP".utf8), "WEBP")
        var chunks: [UInt8] = []
        while body.remaining >= 8 {
            let fourCC = String(decoding: try body.bytes(4, "chunk.fourcc").copyBytes(), as: UTF8.self)
            let n = Int(try body.u32le("chunk.size"))
            var data = try body.bytes(n, "chunk.data").copyBytes()
            if n % 2 == 1, !body.isAtEnd { try body.skip(1, "chunk.pad") }
            guard webpKept.contains(fourCC) else { continue }
            if fourCC == "VP8X", !data.isEmpty { data[0] &= ~(0x08 | 0x04) }   // Exif, XMP flags
            chunks += Array(fourCC.utf8) + le32(n) + data
            if n % 2 == 1 { chunks.append(0) }
        }
        return Array("RIFF".utf8) + le32(chunks.count + 4) + Array("WEBP".utf8) + chunks
    }

    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    // MARK: GIF

    static func gif(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        var c = ByteCursor(bytes)
        let header = try c.bytes(6, "GIF.header")
        guard header.copyBytes() == Array("GIF87a".utf8) || header.copyBytes() == Array("GIF89a".utf8) else {
            throw c.fail("GIF.header", .invalid("not a GIF"))
        }
        let lsd = try c.bytes(7, "GIF.lsd")
        var out = header.copyBytes() + lsd.copyBytes()
        let packed = lsd.copyBytes()[4]
        if packed & 0x80 != 0 { try c.bytes(3 << (Int(packed & 7) + 1), "GIF.gct").append(to: &out) }
        func subBlocks(_ c: inout ByteCursor, into out: inout [UInt8]?) throws(ParseFailure) {
            while true {
                let n = try c.u8("subblock.size")
                let data = try c.bytes(Int(n), "subblock")
                if out != nil { out!.append(n); data.append(to: &out!) }
                if n == 0 { return }
            }
        }
        while true {
            let introducer = try c.u8("block")
            switch introducer {
            case 0x3B:
                out.append(0x3B)
                return out
            case 0x2C:
                let d = try c.bytes(9, "image.descriptor")
                out.append(0x2C)
                d.append(to: &out)
                let p = d.copyBytes()[8]
                if p & 0x80 != 0 { try c.bytes(3 << (Int(p & 7) + 1), "image.lct").append(to: &out) }
                out.append(try c.u8("lzw.minimum"))
                var sink: [UInt8]? = out
                try subBlocks(&c, into: &sink)
                out = sink!
            case 0x21:
                let label = try c.u8("extension.label")
                var keep = label == 0xF9 || label == 0x01
                if label == 0xFF, let first = c.peek(12) {
                    let id = Array(first.copyBytes().dropFirst())
                    keep = id == Array("NETSCAPE2.0".utf8) || id == Array("ANIMEXTS1.0".utf8)
                }
                var sink: [UInt8]? = keep ? [0x21, label] : nil
                try subBlocks(&c, into: &sink)
                if let s = sink { out += s }
            default:
                throw c.fail("block", .invalid("introducer \(introducer)"))
            }
        }
    }
}

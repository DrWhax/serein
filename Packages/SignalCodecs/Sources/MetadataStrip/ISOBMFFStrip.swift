// ISOBMFF metadata removal (see MetadataStrip.swift): MP4 / QuickTime box trees rebuilt
// without user data, and HEIF metadata items zeroed in place.

import CodecCore

/// A box in the original file.
struct BoxSpan {
    var start: Int
    var header: Int
    var size: Int
    var type: String
    var end: Int { start + size }
    var bodyStart: Int { start + header }
}

enum ISOBoxes {
    /// The boxes of `range` in `bytes` (size 0 = to the end, only at top level).
    static func children(_ bytes: [UInt8], _ range: Range<Int>, topLevel: Bool) throws(ParseFailure) -> [BoxSpan] {
        var c = ByteCursor(bytes)
        try c.skip(range.lowerBound, "box")
        var out: [BoxSpan] = []
        var at = range.lowerBound
        while at < range.upperBound {
            guard range.upperBound - at >= 8 else {
                if topLevel { break }
                throw c.fail("box", .unexpectedEnd(needed: 8, available: range.upperBound - at))
            }
            let size32 = Int(try c.u32be("box.size"))
            let type = String(decoding: try c.bytes(4, "box.type").copyBytes(), as: UTF8.self)
            var header = 8, size = size32
            if size32 == 1 {
                size = Int(clamping: try c.u64be("box.largesize"))
                header = 16
            } else if size32 == 0 {
                guard topLevel else { throw c.fail("box.size", .invalid("size 0 inside a container")) }
                size = range.upperBound - at
            }
            guard size >= header, size <= range.upperBound - at else { throw c.fail("box.size", .invalid("\(type) size \(size)")) }
            out.append(BoxSpan(start: at, header: header, size: size, type: type))
            try c.skip(size - header, "box.body")
            at += size
            guard out.count <= 100_000 else { throw c.fail("box", .limitExceeded("too many boxes")) }
        }
        return out
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(b[i]) << 24 | UInt64(b[i + 1]) << 16 | UInt64(b[i + 2]) << 8 | UInt64(b[i + 3]) }
    static func put32(_ v: UInt64, _ out: inout [UInt8], at i: Int) { for k in 0 ..< 4 { out[i + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt64(k))) } }
    static func put64(_ v: UInt64, _ out: inout [UInt8], at i: Int) { for k in 0 ..< 8 { out[i + k] = UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64(k))) } }
}

enum MP4Strip {
    static let topKept: Set<String> = ["ftyp", "moov", "mdat", "moof", "mfra", "wide", "styp", "sidx"]
    static let dropped: Set<String> = ["udta", "meta", "uuid", "free", "skip", "ilst", "keys"]
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex"]
    static let maxDepth = 12

    static func strip(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        let top = try ISOBoxes.children(bytes, 0 ..< bytes.count, topLevel: true)
        guard top.contains(where: { $0.type == "moov" }) else { throw ParseFailure(offset: 0, rule: "moov", reason: .invalid("no movie box")) }
        // Pass 1: the byte ranges that go.
        var removed: [Range<Int>] = []
        for b in top {
            if !topKept.contains(b.type) { removed.append(b.start ..< b.end) }
            if b.type == "moov" { try collect(bytes, b, depth: 0, into: &removed) }
        }
        removed.sort { $0.lowerBound < $1.lowerBound }
        func shift(_ offset: UInt64) -> UInt64 {
            var s: UInt64 = 0
            for r in removed where UInt64(r.upperBound) <= offset { s += UInt64(r.count) }
            return offset - s
        }
        // Pass 2: rebuild.
        var out: [UInt8] = []
        for b in top where topKept.contains(b.type) {
            if b.type == "moov" { out += try rebuild(bytes, b, depth: 0, shift: shift) } else { out += bytes[b.start ..< b.end] }
        }
        return out
    }

    static func collect(_ bytes: [UInt8], _ box: BoxSpan, depth: Int, into removed: inout [Range<Int>]) throws(ParseFailure) {
        guard depth < maxDepth else { throw ParseFailure(offset: box.start, rule: "box", reason: .limitExceeded("depth")) }
        for c in try ISOBoxes.children(bytes, box.bodyStart ..< box.end, topLevel: false) {
            if dropped.contains(c.type) { removed.append(c.start ..< c.end) } else if containers.contains(c.type) { try collect(bytes, c, depth: depth + 1, into: &removed) }
        }
    }

    static func rebuild(_ bytes: [UInt8], _ box: BoxSpan, depth: Int, shift: (UInt64) -> UInt64) throws(ParseFailure) -> [UInt8] {
        var body: [UInt8] = []
        for c in try ISOBoxes.children(bytes, box.bodyStart ..< box.end, topLevel: false) where !dropped.contains(c.type) {
            if containers.contains(c.type) {
                body += try rebuild(bytes, c, depth: depth + 1, shift: shift)
            } else {
                var leaf = Array(bytes[c.start ..< c.end])
                try fix(&leaf, c, shift: shift)
                body += leaf
            }
        }
        return header(box, bodyCount: body.count) + body
    }

    /// The box's header for a new body size (the same header form).
    static func header(_ box: BoxSpan, bodyCount: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: box.header == 16 ? 16 : 8)
        if box.header == 16 {
            ISOBoxes.put32(1, &h, at: 0)
            ISOBoxes.put64(UInt64(bodyCount + 16), &h, at: 8)
        } else {
            ISOBoxes.put32(UInt64(bodyCount + 8), &h, at: 0)
        }
        for (i, ch) in box.type.utf8.prefix(4).enumerated() { h[4 + i] = ch }
        return h
    }

    /// Times zeroed (mvhd / tkhd / mdhd) and chunk offsets moved (stco / co64). `leaf` is the
    /// whole box; its body starts at `box.header`.
    static func fix(_ leaf: inout [UInt8], _ box: BoxSpan, shift: (UInt64) -> UInt64) throws(ParseFailure) {
        let h = box.header
        func need(_ n: Int) throws(ParseFailure) {
            guard leaf.count >= h + n else { throw ParseFailure(offset: box.start, rule: box.type, reason: .unexpectedEnd(needed: n, available: leaf.count - h)) }
        }
        switch box.type {
        case "mvhd", "tkhd", "mdhd":
            try need(4)
            let v1 = leaf[h] == 1
            try need(v1 ? 20 : 12)
            if v1 {
                ISOBoxes.put64(0, &leaf, at: h + 4)
                ISOBoxes.put64(0, &leaf, at: h + 12)
            } else {
                ISOBoxes.put32(0, &leaf, at: h + 4)
                ISOBoxes.put32(0, &leaf, at: h + 8)
            }
        case "stco", "co64":
            try need(8)
            let n = Int(ISOBoxes.u32(leaf, h + 4))
            let w = box.type == "stco" ? 4 : 8
            guard n <= (leaf.count - h - 8) / w else { throw ParseFailure(offset: box.start, rule: box.type, reason: .invalid("\(n) entries")) }
            for i in 0 ..< n {
                let at = h + 8 + i * w
                if w == 4 {
                    ISOBoxes.put32(shift(ISOBoxes.u32(leaf, at)), &leaf, at: at)
                } else {
                    let v = ISOBoxes.u32(leaf, at) << 32 | ISOBoxes.u32(leaf, at + 4)
                    ISOBoxes.put64(shift(v), &leaf, at: at)
                }
            }
        default:
            break
        }
    }
}

enum HEIFStrip {
    static func strip(_ bytes: [UInt8]) throws(ParseFailure) -> [UInt8] {
        var out = bytes
        let top = try ISOBoxes.children(bytes, 0 ..< bytes.count, topLevel: true)
        guard let meta = top.first(where: { $0.type == "meta" }) else { throw ParseFailure(offset: 0, rule: "meta", reason: .invalid("no meta box")) }
        // meta is a full box: version/flags, then children.
        let kids = try ISOBoxes.children(bytes, meta.bodyStart + 4 ..< meta.end, topLevel: false)
        guard let iinf = kids.first(where: { $0.type == "iinf" }) else { return out }
        let targets = try metadataItems(bytes, iinf)
        if targets.isEmpty { return out }
        guard let iloc = kids.first(where: { $0.type == "iloc" }) else { throw ParseFailure(offset: meta.start, rule: "iloc", reason: .invalid("metadata items without locations")) }
        let idat = kids.first { $0.type == "idat" }
        for (method, start, length) in try locations(bytes, iloc, items: targets) {
            let base: Int
            switch method {
            case 0: base = 0
            case 1:
                guard let idat else { throw ParseFailure(offset: iloc.start, rule: "idat", reason: .invalid("missing")) }
                base = idat.bodyStart
            default: throw ParseFailure(offset: iloc.start, rule: "iloc", reason: .invalid("construction method \(method)"))
            }
            let s = base + start
            let limit = method == 1 ? idat!.end : bytes.count
            guard length > 0, s >= 0, s <= limit, length <= limit - s else { throw ParseFailure(offset: iloc.start, rule: "iloc.extent", reason: .invalid("extent \(s)+\(length)")) }
            for i in s ..< s + length { out[i] = 0 }
        }
        return out
    }

    /// IDs of Exif items and XMP (`mime` application/rdf+xml) items.
    static func metadataItems(_ bytes: [UInt8], _ iinf: BoxSpan) throws(ParseFailure) -> Set<UInt32> {
        var c = ByteCursor(bytes)
        try c.skip(iinf.bodyStart, "iinf")
        let version = try c.u8("iinf.version")
        try c.skip(3, "iinf.flags")
        _ = version == 0 ? UInt32(try c.u16be("iinf.count")) : try c.u32be("iinf.count")
        let entriesStart = iinf.bodyStart + 4 + (version == 0 ? 2 : 4)
        var ids: Set<UInt32> = []
        for e in try ISOBoxes.children(bytes, entriesStart ..< iinf.end, topLevel: false) where e.type == "infe" {
            var d = ByteCursor(bytes)
            try d.skip(e.bodyStart, "infe")
            let v = try d.u8("infe.version")
            try d.skip(3, "infe.flags")
            guard v >= 2 else { continue }
            let id = v == 2 ? UInt32(try d.u16be("infe.id")) : try d.u32be("infe.id")
            try d.skip(2, "infe.protection")
            let type = String(decoding: try d.bytes(4, "infe.type").copyBytes(), as: UTF8.self)
            if type == "Exif" { ids.insert(id) }
            if type == "mime" {
                let rest = try d.bytes(e.end - d.consumed, "infe.rest").copyBytes()
                // item_name\0 content_type\0 …
                let parts = rest.split(separator: 0, omittingEmptySubsequences: false)
                if parts.count >= 2, String(decoding: parts[1], as: UTF8.self).lowercased().hasPrefix("application/rdf+xml") { ids.insert(id) }
            }
        }
        return ids
    }

    /// (construction method, offset, length) of every extent of `items`.
    static func locations(_ bytes: [UInt8], _ iloc: BoxSpan, items: Set<UInt32>) throws(ParseFailure) -> [(Int, Int, Int)] {
        var c = ByteCursor(bytes)
        try c.skip(iloc.bodyStart, "iloc")
        let version = try c.u8("iloc.version")
        try c.skip(3, "iloc.flags")
        let a = try c.u8("iloc.sizes"), b = try c.u8("iloc.sizes")
        let offsetSize = Int(a >> 4), lengthSize = Int(a & 15), baseSize = Int(b >> 4), indexSize = version >= 1 ? Int(b & 15) : 0
        for s in [offsetSize, lengthSize, baseSize, indexSize] where ![0, 4, 8].contains(s) {
            throw c.fail("iloc.sizes", .invalid("field size \(s)"))
        }
        func field(_ n: Int) throws(ParseFailure) -> Int {
            switch n {
            case 4: Int(try c.u32be("iloc.field"))
            case 8: Int(clamping: try c.u64be("iloc.field"))
            default: 0
            }
        }
        let count = version < 2 ? Int(try c.u16be("iloc.count")) : Int(try c.u32be("iloc.count"))
        var out: [(Int, Int, Int)] = []
        for _ in 0 ..< count {
            let id = version < 2 ? UInt32(try c.u16be("iloc.id")) : try c.u32be("iloc.id")
            let method = version >= 1 ? Int(try c.u16be("iloc.method") & 15) : 0
            try c.skip(2, "iloc.dataReference")
            let base = try field(baseSize)
            let extents = Int(try c.u16be("iloc.extents"))
            for _ in 0 ..< extents {
                _ = try field(indexSize)
                let off = try field(offsetSize), len = try field(lengthSize)
                if items.contains(id) {
                    let (s, o) = base.addingReportingOverflow(off)
                    guard !o else { throw c.fail("iloc.extent", .invalid("overflow")) }
                    out.append((method, s, len))
                }
            }
        }
        return out
    }
}

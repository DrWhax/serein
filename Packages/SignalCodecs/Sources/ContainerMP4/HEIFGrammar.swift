// ISO/IEC 23008-12 (HEIF) and the AVIF / MIAF item grammar, over the ISOBMFF box tree that
// MP4 uses (BoxGrammar): the meta box of a still image file.
//
//   file      := ftyp meta other*                  (moov / mdat / free … allowed; one meta)
//   meta      := full(0) hdlr('pict') pitm iloc iinf iref? iprp idat? dinf? other*
//   pitm      := full(v) item_ID:(v == 0 ? u16 : u32)
//   iloc      := full(v<3) offset_size:4 length_size:4 base_offset_size:4 (v ≥ 1 ? index_size:4 : reserved:4)
//                count:(v < 2 ? u16 : u32)
//                ( item_ID:(v < 2 ? u16 : u32) [v ≥ 1: reserved:12 construction_method:4] data_reference_index:u16
//                  base_offset:base_offset_size extent_count:u16
//                  ( [v ≥ 1 ∧ index_size > 0: extent_index] extent_offset extent_length ){extent_count} ){count}
//                field sizes ∈ {0, 4, 8}; construction 0 = file offsets, 1 = in idat; data_reference_index 0
//   iinf      := full(v) entry_count:(v == 0 ? u16 : u32) infe*
//   infe      := full(v ∈ 2…3, flags: bit 0 = hidden) item_ID:(v == 2 ? u16 : u32) protection_index:u16
//                item_type:4cc item_name:cstring [mime: content_type:cstring content_encoding:cstring?]
//   iref      := full(v) ( box(reference_type) from_item_ID ref_count:u16 to_item_ID{ref_count} )*   (IDs u16 / u32)
//   iprp      := ipco ipma+
//   ipco      := property box*                     (1-based indices)
//   ipma      := full(v, flags) entry_count:u32 ( item_ID:(v < 1 ? u16 : u32) association_count:u8
//                ( essential:1 property_index:(flags & 1 ? 15 : 7) ){association_count} )*
//   properties:
//     ispe := full(0) width:u32 height:u32            pixi := full(0) n:u8 bits:u8{n}
//     colr := 'nclx' primaries:u16 transfer:u16 matrix:u16 full_range:1 reserved:7 | ('rICC'|'prof') icc
//     irot := reserved:6 angle:2 (×90° anticlockwise)   imir := reserved:7 mode:1 (0 = top ↔ bottom)
//     clap := (widthN widthD heightN heightD horizOffN horizOffD vertOffN vertOffD):u32 (offsets' N signed)
//     auxC := full(0) aux_type:cstring aux_subtype:rest
//     hvcC := HEVCDecoderConfigurationRecord (MP4Demuxer.parseHvcC)
//     av1C := marker:1(1) version:7(1) seq_profile:3 seq_level_idx_0:5 seq_tier_0:1 high_bitdepth:1
//             twelve_bit:1 monochrome:1 subsampling_x:1 subsampling_y:1 chroma_sample_position:2
//             reserved:3 initial_presentation_delay_present:1 delay_minus_one:4 configOBUs:rest
//   grid item payload := version:u8(0) flags:u8 rows_minus_one:u8 columns_minus_one:u8
//             output_width, output_height:(flags & 1 ? u32 : u16)
//
// Every count is bounded (HEIFLimits) before it sizes anything; every extent is checked
// against the file (or idat) before it becomes a slice. Item payloads are slices of the input.

public import CodecCore

public struct HEIFLimits: Sendable {
    public var maxItems = 4096
    public var maxProperties = 4096
    public var maxReferences = 16_384
    public var maxExtentsPerItem = 1024
    public var maxBoxes = 20_000
    public init() {}
}

public enum HEIFColour: Sendable, Equatable {
    case nclx(primaries: Int, transfer: Int, matrix: Int, fullRange: Bool)
    case icc
}

/// AV1CodecConfigurationRecord (AV1-ISOBMFF 2.3).
public struct AV1CodecConfiguration: Sendable, Equatable {
    public var seqProfile: Int
    public var seqLevelIdx0: Int
    public var highBitDepth: Bool
    public var twelveBit: Bool
    public var monochrome: Bool
    public var subsamplingX: Bool
    public var subsamplingY: Bool
    /// Sequence header (and metadata) OBUs, low-overhead format.
    public var configOBUs: ByteSlice
}

/// A clean-aperture box: fractions as written.
public struct HEIFCleanAperture: Sendable, Equatable {
    public var widthN: UInt32, widthD: UInt32
    public var heightN: UInt32, heightD: UInt32
    public var horizOffN: Int32, horizOffD: UInt32
    public var vertOffN: Int32, vertOffD: UInt32
}

public enum HEIFProperty: Sendable, Equatable {
    case hvcC(HEVCDecoderConfiguration)
    case av1C(AV1CodecConfiguration)
    case ispe(width: Int, height: Int)
    case pixi(bits: [Int])
    case colr(HEIFColour)
    /// Anticlockwise rotation in units of 90°.
    case irot(Int)
    /// imir mode (23008-12:2022): 0 = top and bottom exchanged, 1 = left and right exchanged.
    case imir(Int)
    case clap(HEIFCleanAperture)
    case auxC(type: String, subtype: ByteSlice)
    /// Any other property (pasp, clli, mdcv, lsel, a1op, …), by type.
    case other(FourCC)

    /// Whether the property changes the image's geometry (applied in association order).
    public var isTransformative: Bool {
        switch self {
        case .irot, .imir, .clap: true
        default: false
        }
    }
}

public struct HEIFItem: Sendable, Equatable {
    public var id: UInt32
    public var type: FourCC
    public var hidden: Bool
    public var contentType: String?
    /// The item's bytes: its extents in order (empty for an item without a location).
    public var extents: [ByteSlice]
    /// (essential, property) in association order.
    public var properties: [(essential: Bool, property: HEIFProperty)]

    public var data: ByteSlice { ByteSlice.concatenate(extents) }

    public static func == (a: HEIFItem, b: HEIFItem) -> Bool {
        a.id == b.id && a.type == b.type && a.hidden == b.hidden && a.contentType == b.contentType && a.extents == b.extents
            && a.properties.map(\.essential) == b.properties.map(\.essential) && a.properties.map(\.property) == b.properties.map(\.property)
    }

    public var spatialExtent: (width: Int, height: Int)? {
        for (_, p) in properties { if case .ispe(let w, let h) = p { return (w, h) } }
        return nil
    }

    public var hevcConfiguration: HEVCDecoderConfiguration? {
        for (_, p) in properties { if case .hvcC(let c) = p { return c } }
        return nil
    }

    public var av1Configuration: AV1CodecConfiguration? {
        for (_, p) in properties { if case .av1C(let c) = p { return c } }
        return nil
    }

    public var colour: HEIFColour? {
        // A file may carry both nclx and an ICC profile; the nclx one says how to convert.
        var icc: HEIFColour? = nil
        for (_, p) in properties {
            if case .colr(let c) = p {
                if case .nclx = c { return c }
                icc = c
            }
        }
        return icc
    }

    public var auxiliaryType: String? {
        for (_, p) in properties { if case .auxC(let t, _) = p { return t } }
        return nil
    }
}

public struct HEIFReference: Sendable, Equatable {
    public var type: FourCC
    public var from: UInt32
    public var to: [UInt32]
}

/// ImageGrid (23008-12 6.6.2.3).
public struct HEIFGrid: Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var outputWidth: Int
    public var outputHeight: Int
}

public struct HEIFFile: Sendable, Equatable {
    public var majorBrand: FourCC
    public var compatibleBrands: [FourCC]
    public var primaryItemID: UInt32
    public var items: [HEIFItem]
    public var references: [HEIFReference]

    public func item(_ id: UInt32) -> HEIFItem? { items.first { $0.id == id } }

    /// The targets of `from`'s references of `type`, in order.
    public func references(_ type: String, from id: UInt32) -> [UInt32] {
        references.filter { $0.type == FourCC(type) && $0.from == id }.flatMap(\.to)
    }

    /// Items that reference `to` with `type` (e.g. the auxl alpha planes of an image).
    public func referrers(_ type: String, to id: UInt32) -> [UInt32] {
        references.filter { $0.type == FourCC(type) && $0.to.contains(id) }.map(\.from)
    }

    public func hasBrand(_ b: String) -> Bool { majorBrand == FourCC(b) || compatibleBrands.contains(FourCC(b)) }
}

public enum HEIFParser {
    static func t(_ s: String) -> FourCC { FourCC(s) }

    public static func parse(_ bytes: [UInt8], limits: HEIFLimits = HEIFLimits()) throws(ParseFailure) -> HEIFFile {
        try parse(ByteSlice(bytes), limits: limits)
    }

    public static func parse(_ file: ByteSlice, limits: HEIFLimits = HEIFLimits()) throws(ParseFailure) -> HEIFFile {
        var boxLimits = MP4Limits()
        boxLimits.maxBoxes = limits.maxBoxes
        var count = 0
        let top = try BoxGrammar.children(file, topLevel: true, limits: boxLimits, count: &count)
        guard let ftyp = top.first, ftyp.type == t("ftyp") else {
            throw ParseFailure(offset: 0, rule: "file", reason: .mismatch(expected: "ftyp first"))
        }
        var fc = ftyp.body.cursor()
        let major = try fc.u32be("ftyp.major_brand")
        _ = try fc.u32be("ftyp.minor_version")
        var compatible: [FourCC] = []
        while fc.remaining >= 4 { compatible.append(try fc.u32be("ftyp.compatible_brand")) }
        let metas = top.filter { $0.type == t("meta") }
        guard metas.count == 1, let meta = metas.first else {
            throw ParseFailure(offset: ftyp.offset, rule: "file", reason: .invalid("\(metas.count) top-level meta boxes"))
        }
        var mc = meta.body.cursor()
        let (mv, _) = try BoxGrammar.fullBox(&mc)
        guard mv == 0 else { throw mc.fail("meta.version", .invalid("version \(mv)")) }
        let kids = try BoxGrammar.children(mc.rest(), topLevel: false, limits: boxLimits, count: &count)
        func one(_ type: String, required: Bool = true) throws(ParseFailure) -> Box? {
            let found = kids.filter { $0.type == t(type) }
            guard found.count <= 1 else { throw ParseFailure(offset: found[1].offset, rule: "meta", reason: .invalid("more than one \(type)")) }
            if required, found.isEmpty { throw ParseFailure(offset: meta.offset, rule: "meta", reason: .mismatch(expected: type)) }
            return found.first
        }
        guard let hdlr = try one("hdlr") else { throw ParseFailure(offset: meta.offset, rule: "meta", reason: .mismatch(expected: "hdlr")) }
        var hc = hdlr.body.cursor()
        _ = try BoxGrammar.fullBox(&hc)
        _ = try hc.u32be("hdlr.pre_defined")
        let handler = try hc.u32be("hdlr.handler_type")
        guard handler == t("pict") else { throw hc.fail("hdlr.handler_type", .mismatch(expected: "pict")) }

        guard let pitm = try one("pitm") else { throw ParseFailure(offset: meta.offset, rule: "meta", reason: .mismatch(expected: "pitm")) }
        var pc = pitm.body.cursor()
        let (pv, _) = try BoxGrammar.fullBox(&pc)
        let primary = pv == 0 ? UInt32(try pc.u16be("pitm.item_ID")) : try pc.u32be("pitm.item_ID")

        guard let iinf = try one("iinf") else { throw ParseFailure(offset: meta.offset, rule: "meta", reason: .mismatch(expected: "iinf")) }
        var items = try parseIinf(iinf, limits: limits, boxLimits: boxLimits, count: &count)

        let idat = try one("idat", required: false)
        if let iloc = try one("iloc", required: false) {
            let locations = try parseIloc(iloc, file: file, idat: idat?.body, limits: limits)
            for (id, extents) in locations {
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].extents = extents
            }
        }

        var references: [HEIFReference] = []
        if let iref = try one("iref", required: false) {
            references = try parseIref(iref, limits: limits, boxLimits: boxLimits, count: &count)
        }

        if let iprp = try one("iprp", required: false) {
            let pkids = try BoxGrammar.children(iprp.body, topLevel: false, limits: boxLimits, count: &count)
            let ipcos = pkids.filter { $0.type == t("ipco") }
            guard ipcos.count == 1, let ipco = ipcos.first else { throw ParseFailure(offset: iprp.offset, rule: "iprp", reason: .invalid("\(ipcos.count) ipco boxes")) }
            let propBoxes = try BoxGrammar.children(ipco.body, topLevel: false, limits: boxLimits, count: &count)
            guard propBoxes.count <= limits.maxProperties else { throw ParseFailure(offset: ipco.offset, rule: "ipco", reason: .limitExceeded("\(propBoxes.count) properties")) }
            var props: [HEIFProperty] = []
            props.reserveCapacity(propBoxes.count)
            for b in propBoxes { props.append(try parseProperty(b)) }
            var associated: Set<UInt32> = []
            for ipma in pkids where ipma.type == t("ipma") {
                for (id, list) in try parseIpma(ipma, propertyCount: props.count, limits: limits) {
                    // Each item is associated in at most one ipma entry (23008-12 9.3.1).
                    guard associated.insert(id).inserted else { throw ParseFailure(offset: ipma.offset, rule: "ipma", reason: .invalid("item \(id) twice")) }
                    guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                    items[i].properties = list.map { (essential: $0.essential, property: props[$0.index - 1]) }
                }
            }
        }
        guard items.contains(where: { $0.id == primary }) else {
            throw ParseFailure(offset: pitm.offset, rule: "pitm", reason: .invalid("primary item \(primary) has no infe"))
        }
        return HEIFFile(majorBrand: major, compatibleBrands: compatible, primaryItemID: primary, items: items, references: references)
    }

    /// A null-terminated UTF-8 string (a missing terminator at the end of the box is tolerated).
    static func cstring(_ c: inout ByteCursor, _ rule: String) throws(ParseFailure) -> String {
        var b: [UInt8] = []
        while let v = c.peekU8() {
            _ = try c.u8(rule)
            if v == 0 { break }
            b.append(v)
            guard b.count <= 4096 else { throw c.fail(rule, .limitExceeded("string longer than 4096 bytes")) }
        }
        return String(decoding: b, as: UTF8.self)
    }

    static func parseIinf(_ iinf: Box, limits: HEIFLimits, boxLimits: MP4Limits, count: inout Int) throws(ParseFailure) -> [HEIFItem] {
        var c = iinf.body.cursor()
        let (v, _) = try BoxGrammar.fullBox(&c)
        let n = v == 0 ? Int(try c.u16be("iinf.entry_count")) : Int(try c.u32be("iinf.entry_count"))
        guard n <= limits.maxItems else { throw c.fail("iinf.entry_count", .limitExceeded("\(n) items")) }
        let entries = try BoxGrammar.children(c.rest(), topLevel: false, limits: boxLimits, count: &count)
        guard entries.count == n else {
            throw ParseFailure(offset: iinf.offset, rule: "iinf", reason: .invalid("entry_count \(n), \(entries.count) boxes"))
        }
        var items: [HEIFItem] = []
        var ids: Set<UInt32> = []
        for e in entries {
            guard e.type == t("infe") else { throw ParseFailure(offset: e.offset, rule: "iinf", reason: .mismatch(expected: "infe")) }
            var d = e.body.cursor()
            let (ev, flags) = try BoxGrammar.fullBox(&d)
            // Versions 0 and 1 describe files, not image items (23008-12 9.2).
            guard ev >= 2 else { continue }
            guard ev <= 3 else { throw d.fail("infe.version", .invalid("version \(ev)")) }
            let id = ev == 2 ? UInt32(try d.u16be("infe.item_ID")) : try d.u32be("infe.item_ID")
            let protection = try d.u16be("infe.item_protection_index")
            let type = try d.u32be("infe.item_type")
            _ = try cstring(&d, "infe.item_name")
            var contentType: String? = nil
            if type == t("mime") { contentType = try cstring(&d, "infe.content_type") }
            guard ids.insert(id).inserted else { throw d.fail("infe.item_ID", .invalid("item \(id) twice")) }
            // A protected item is kept only as an opaque item: it is never decoded.
            items.append(HEIFItem(id: id, type: protection == 0 ? type : t("prot"), hidden: flags & 1 != 0, contentType: contentType,
                                  extents: [], properties: []))
        }
        return items
    }

    static func parseIloc(_ iloc: Box, file: ByteSlice, idat: ByteSlice?, limits: HEIFLimits) throws(ParseFailure) -> [(UInt32, [ByteSlice])] {
        var c = iloc.body.cursor()
        let (v, _) = try BoxGrammar.fullBox(&c)
        guard v <= 2 else { throw c.fail("iloc.version", .invalid("version \(v)")) }
        let a = try c.u8("iloc.offset_size·length_size"), b = try c.u8("iloc.base_offset_size·index_size")
        let offsetSize = Int(a >> 4), lengthSize = Int(a & 15), baseSize = Int(b >> 4), indexSize = v >= 1 ? Int(b & 15) : 0
        for s in [offsetSize, lengthSize, baseSize, indexSize] where ![0, 4, 8].contains(s) {
            throw c.fail("iloc.field_size", .invalid("field size \(s)"))
        }
        func field(_ n: Int, _ rule: String) throws(ParseFailure) -> UInt64 {
            switch n {
            case 4: UInt64(try c.u32be(rule))
            case 8: try c.u64be(rule)
            default: 0
            }
        }
        let n = v < 2 ? Int(try c.u16be("iloc.item_count")) : Int(try c.u32be("iloc.item_count"))
        guard n <= limits.maxItems else { throw c.fail("iloc.item_count", .limitExceeded("\(n) items")) }
        var out: [(UInt32, [ByteSlice])] = []
        var ids: Set<UInt32> = []
        for _ in 0..<n {
            let id = v < 2 ? UInt32(try c.u16be("iloc.item_ID")) : try c.u32be("iloc.item_ID")
            guard ids.insert(id).inserted else { throw c.fail("iloc.item_ID", .invalid("item \(id) twice")) }
            let method = v >= 1 ? Int(try c.u16be("iloc.construction_method") & 15) : 0
            let dref = try c.u16be("iloc.data_reference_index")
            let base = try field(baseSize, "iloc.base_offset")
            let extentCount = Int(try c.u16be("iloc.extent_count"))
            guard extentCount <= limits.maxExtentsPerItem else { throw c.fail("iloc.extent_count", .limitExceeded("\(extentCount) extents")) }
            var extents: [ByteSlice] = []
            for _ in 0..<extentCount {
                _ = try field(indexSize, "iloc.extent_index")
                let off = try field(offsetSize, "iloc.extent_offset"), len = try field(lengthSize, "iloc.extent_length")
                // Only this file's own data (no external data references, no item-offset construction).
                guard dref == 0 else { throw c.fail("iloc.data_reference_index", .invalid("external data")) }
                let source: ByteSlice
                switch method {
                case 0: source = file
                case 1:
                    guard let idat else { throw c.fail("iloc.construction_method", .invalid("idat construction without idat")) }
                    source = idat
                default: throw c.fail("iloc.construction_method", .invalid("construction method \(method)"))
                }
                let (start, o) = base.addingReportingOverflow(off)
                guard !o, start <= UInt64(source.count) else { throw c.fail("iloc.extent_offset", .invalid("extent outside the data")) }
                // Length 0: the rest of the data.
                let length = len == 0 ? UInt64(source.count) - start : len
                guard length <= UInt64(source.count) - start else { throw c.fail("iloc.extent_length", .invalid("extent outside the data")) }
                var sc = source.cursor()
                // File offsets are absolute; idat offsets are relative to idat's body.
                try sc.skip(Int(start), "iloc.extent")
                extents.append(try sc.bytes(Int(length), "iloc.extent"))
            }
            out.append((id, extents))
        }
        return out
    }

    static func parseIref(_ iref: Box, limits: HEIFLimits, boxLimits: MP4Limits, count: inout Int) throws(ParseFailure) -> [HEIFReference] {
        var c = iref.body.cursor()
        let (v, _) = try BoxGrammar.fullBox(&c)
        guard v <= 1 else { throw c.fail("iref.version", .invalid("version \(v)")) }
        var out: [HEIFReference] = []
        var total = 0
        for b in try BoxGrammar.children(c.rest(), topLevel: false, limits: boxLimits, count: &count) {
            var d = b.body.cursor()
            let from = v == 0 ? UInt32(try d.u16be("iref.from_item_ID")) : try d.u32be("iref.from_item_ID")
            let n = Int(try d.u16be("iref.reference_count"))
            total += n
            guard total <= limits.maxReferences else { throw d.fail("iref.reference_count", .limitExceeded("\(total) references")) }
            var to: [UInt32] = []
            to.reserveCapacity(n)
            for _ in 0..<n { to.append(v == 0 ? UInt32(try d.u16be("iref.to_item_ID")) : try d.u32be("iref.to_item_ID")) }
            try d.expectEnd("iref.\(b.type.fourCCString)")
            out.append(HEIFReference(type: b.type, from: from, to: to))
        }
        return out
    }

    static func parseIpma(_ ipma: Box, propertyCount: Int, limits: HEIFLimits) throws(ParseFailure) -> [(UInt32, [(essential: Bool, index: Int)])] {
        var c = ipma.body.cursor()
        let (v, flags) = try BoxGrammar.fullBox(&c)
        guard v <= 1 else { throw c.fail("ipma.version", .invalid("version \(v)")) }
        let n = Int(try c.u32be("ipma.entry_count"))
        guard n <= limits.maxItems else { throw c.fail("ipma.entry_count", .limitExceeded("\(n) entries")) }
        var out: [(UInt32, [(essential: Bool, index: Int)])] = []
        for _ in 0..<n {
            let id = v < 1 ? UInt32(try c.u16be("ipma.item_ID")) : try c.u32be("ipma.item_ID")
            let k = Int(try c.u8("ipma.association_count"))
            var list: [(essential: Bool, index: Int)] = []
            for _ in 0..<k {
                let (essential, index): (Bool, Int)
                if flags & 1 != 0 {
                    let x = try c.u16be("ipma.property_index")
                    (essential, index) = (x & 0x8000 != 0, Int(x & 0x7FFF))
                } else {
                    let x = try c.u8("ipma.property_index")
                    (essential, index) = (x & 0x80 != 0, Int(x & 0x7F))
                }
                // Index 0: no property.
                if index == 0 { continue }
                guard index <= propertyCount else { throw c.fail("ipma.property_index", .invalid("property \(index) of \(propertyCount)")) }
                list.append((essential, index))
            }
            out.append((id, list))
        }
        return out
    }

    static func parseProperty(_ b: Box) throws(ParseFailure) -> HEIFProperty {
        var c = b.body.cursor()
        switch b.type.fourCCString {
        case "hvcC": return .hvcC(try MP4Demuxer.parseHvcC(b.body))
        case "av1C": return .av1C(try parseAv1C(b.body))
        case "ispe":
            _ = try BoxGrammar.fullBox(&c)
            let w = Int(try c.u32be("ispe.image_width")), h = Int(try c.u32be("ispe.image_height"))
            return .ispe(width: w, height: h)
        case "pixi":
            _ = try BoxGrammar.fullBox(&c)
            let n = Int(try c.u8("pixi.num_channels"))
            var bits: [Int] = []
            for _ in 0..<n { bits.append(Int(try c.u8("pixi.bits_per_channel"))) }
            return .pixi(bits: bits)
        case "colr":
            let type = try c.u32be("colr.colour_type")
            if type == t("nclx") {
                let p = Int(try c.u16be("colr.colour_primaries")), tr = Int(try c.u16be("colr.transfer_characteristics"))
                let m = Int(try c.u16be("colr.matrix_coefficients"))
                let f = try c.u8("colr.full_range_flag") & 0x80 != 0
                return .colr(.nclx(primaries: p, transfer: tr, matrix: m, fullRange: f))
            }
            if type == t("rICC") || type == t("prof") { return .colr(.icc) }
            return .other(b.type)
        case "irot": return .irot(Int(try c.u8("irot.angle") & 3))
        case "imir": return .imir(Int(try c.u8("imir.axis") & 1))
        case "clap":
            let wn = try c.u32be("clap.widthN"), wd = try c.u32be("clap.widthD")
            let hn = try c.u32be("clap.heightN"), hd = try c.u32be("clap.heightD")
            let xn = Int32(bitPattern: try c.u32be("clap.horizOffN")), xd = try c.u32be("clap.horizOffD")
            let yn = Int32(bitPattern: try c.u32be("clap.vertOffN")), yd = try c.u32be("clap.vertOffD")
            return .clap(HEIFCleanAperture(widthN: wn, widthD: wd, heightN: hn, heightD: hd, horizOffN: xn, horizOffD: xd, vertOffN: yn, vertOffD: yd))
        case "auxC":
            _ = try BoxGrammar.fullBox(&c)
            let type = try cstring(&c, "auxC.aux_type")
            return .auxC(type: type, subtype: c.rest())
        default: return .other(b.type)
        }
    }

    public static func parseAv1C(_ body: ByteSlice) throws(ParseFailure) -> AV1CodecConfiguration {
        var c = body.cursor()
        _ = try c.u8("av1C.marker·version", require: "marker 1, version 1") { $0 == 0x81 }
        let a = try c.u8("av1C.seq_profile·seq_level_idx_0")
        let b = try c.u8("av1C.flags")
        _ = try c.u8("av1C.initial_presentation_delay")
        return AV1CodecConfiguration(seqProfile: Int(a >> 5), seqLevelIdx0: Int(a & 31), highBitDepth: b & 0x40 != 0, twelveBit: b & 0x20 != 0,
                                     monochrome: b & 0x10 != 0, subsamplingX: b & 0x08 != 0, subsamplingY: b & 0x04 != 0, configOBUs: c.rest())
    }

    /// The payload of a `grid` item.
    public static func parseGrid(_ data: ByteSlice) throws(ParseFailure) -> HEIFGrid {
        var c = data.cursor()
        _ = try c.u8("grid.version", require: "version 0") { $0 == 0 }
        let flags = try c.u8("grid.flags")
        let rows = Int(try c.u8("grid.rows_minus_one")) + 1, cols = Int(try c.u8("grid.columns_minus_one")) + 1
        let w = flags & 1 != 0 ? Int(try c.u32be("grid.output_width")) : Int(try c.u16be("grid.output_width"))
        let h = flags & 1 != 0 ? Int(try c.u32be("grid.output_height")) : Int(try c.u16be("grid.output_height"))
        return HEIFGrid(rows: rows, columns: cols, outputWidth: w, outputHeight: h)
    }

    /// Whether `bytes` start like a HEIF file: an ftyp whose brands name a HEIF image structure.
    public static func brands(_ bytes: [UInt8]) -> (major: FourCC, compatible: [FourCC])? {
        var c = ByteCursor(bytes)
        guard let size = try? c.u32be(), size >= 16, size <= 4096, Int(size) <= bytes.count, let type = try? c.u32be(), type == t("ftyp"),
              let major = try? c.u32be(), (try? c.u32be()) != nil else { return nil }
        var compatible: [FourCC] = []
        for _ in 0..<((Int(size) - 16) / 4) { if let b = try? c.u32be() { compatible.append(b) } }
        return (major, compatible)
    }
}

// HEIF still images (ISO/IEC 23008-12, MIAF; HEIC = HEVC items, AVIF = AV1 items): the
// primary item, decoded and composed.
//
//   primary  := coded item (hvc1 | av01) | grid of coded items | iden of one of those
//   grid     := ImageGrid payload + dimg references (row-major tiles, all the same size and
//               format), placed and cropped to the output size; tiles decode in parallel
//   alpha    := an auxl item referring to the primary, auxC alpha (HEVC or MPEG-B URN),
//               optionally premultiplied (prem reference)
//   geometry := the primary's clap / irot / imir, applied in association order
//
// Callers name the codecs they accept: received images are AVIF only (upstream displays
// AVIF, never HEIC), and HEIC is decoded only on the sending side. An item with an essential
// property this decoder does not understand is refused, as the specification requires.

public import CodecCore
import ContainerMP4
import Dispatch
import Synchronization
import VideoAV1
import VideoHEVC

public enum HEIFCodec: Sendable, Hashable {
    case hevc, av1
}

/// A decoded (or composed) image item before conversion: planes of `bitDepth`-bit samples.
public struct HEIFPlanes: Sendable {
    public var width: Int, height: Int
    public var bitDepth: Int
    /// 0 = 4:0:0, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    public var chromaFormat: Int
    public var y: [UInt16], u: [UInt16], v: [UInt16]
    public var colour: HEIFColourInfo

    public var subsamplingX: Int { chromaFormat == 1 || chromaFormat == 2 ? 1 : 0 }
    public var subsamplingY: Int { chromaFormat == 1 ? 1 : 0 }
    public var chromaWidth: Int { chromaFormat == 0 ? 0 : (width + subsamplingX) >> subsamplingX }
    public var chromaHeight: Int { chromaFormat == 0 ? 0 : (height + subsamplingY) >> subsamplingY }
}

/// H.273 colour description (code points).
public struct HEIFColourInfo: Sendable, Equatable {
    public var primaries = 2, transfer = 2, matrix = 2
    public var fullRange = false
    public init(primaries: Int = 2, transfer: Int = 2, matrix: Int = 2, fullRange: Bool = false) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
    }
}

public struct HEIFImage: Sendable {
    public var image: PixelBuffer
    public var codec: HEIFCodec
    public var hasAlpha: Bool
    public var bitDepth: Int
}

public enum HEIFDecoder {
    static let alphaURNs: Set<String> = ["urn:mpeg:hevc:2015:auxid:1", "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha"]
    /// Properties this decoder understands (an unknown essential one makes the item undecodable).
    static func understood(_ p: HEIFProperty) -> Bool {
        if case .other(let t) = p { return ["pasp", "clli", "mdcv", "cclv", "amve"].contains(t.fourCCString) }
        return true
    }

    /// The codec of the primary item (after following grid / iden), without decoding.
    public static func primaryCodec(_ bytes: [UInt8]) -> HEIFCodec? {
        guard let file = try? HEIFParser.parse(bytes), let item = file.item(file.primaryItemID) else { return nil }
        return codec(of: item, in: file, depth: 0)
    }

    static func codec(of item: HEIFItem, in file: HEIFFile, depth: Int) -> HEIFCodec? {
        switch item.type.fourCCString {
        case "hvc1": return .hevc
        case "av01": return .av1
        case "grid", "iden":
            guard depth < 2, let first = file.references("dimg", from: item.id).first, let tile = file.item(first) else { return nil }
            return codec(of: tile, in: file, depth: depth + 1)
        default: return nil
        }
    }

    /// The primary image as RGBA8 (straight alpha), geometry applied.
    public static func decode(_ bytes: [UInt8], codecs: Set<HEIFCodec>, limits: DecodeLimits = .default) throws(ParseFailure) -> HEIFImage {
        guard bytes.count <= limits.maxInputBytes else { throw ParseFailure(offset: 0, rule: "heif", reason: .limitExceeded("\(bytes.count) bytes")) }
        let file = try HEIFParser.parse(bytes)
        guard let primary = file.item(file.primaryItemID) else { throw ParseFailure(offset: 0, rule: "pitm", reason: .invalid("no primary item")) }
        guard let codec = codec(of: primary, in: file, depth: 0) else {
            throw ParseFailure(offset: 0, rule: "heif.primary", reason: .invalid("item type \(primary.type.fourCCString)"))
        }
        guard codecs.contains(codec) else { throw ParseFailure(offset: 0, rule: "heif.primary", reason: .invalid("\(codec) images are not accepted here")) }
        let colour = try planes(of: primary, in: file, codec: codec, limits: limits, depth: 0)
        // Alpha: an auxiliary image of the primary item.
        var alpha: HEIFPlanes? = nil
        var premultiplied = false
        for id in file.referrers("auxl", to: primary.id) {
            guard let a = file.item(id), let urn = a.auxiliaryType, alphaURNs.contains(urn) else { continue }
            let p = try planes(of: a, in: file, codec: codec, limits: limits, depth: 0)
            guard p.width == colour.width, p.height == colour.height else {
                throw ParseFailure(offset: 0, rule: "heif.alpha", reason: .invalid("alpha \(p.width)x\(p.height) for \(colour.width)x\(colour.height)"))
            }
            alpha = p
            premultiplied = file.references("prem", from: primary.id).contains(id)
            break
        }
        var rgba = HEIFColourConvert.rgba(colour, alpha: alpha, premultiplied: premultiplied)
        var w = colour.width, h = colour.height
        for (_, p) in primary.properties where p.isTransformative {
            switch p {
            case .clap(let c): (w, h, rgba) = try HEIFTransform.crop(rgba, w, h, c)
            case .irot(let a): (w, h, rgba) = HEIFTransform.rotateAnticlockwise(rgba, w, h, quarterTurns: a)
            case .imir(let axis): rgba = HEIFTransform.mirror(rgba, w, h, axis: axis)
            default: break
            }
        }
        return HEIFImage(image: PixelBuffer(width: w, height: h, rgba: rgba), codec: codec, hasAlpha: alpha != nil, bitDepth: colour.bitDepth)
    }

    static func checkEssentials(_ item: HEIFItem) throws(ParseFailure) {
        for (essential, p) in item.properties where essential && !understood(p) {
            if case .other(let t) = p {
                throw ParseFailure(offset: 0, rule: "heif.ipma", reason: .invalid("essential property \(t.fourCCString) on item \(item.id)"))
            }
        }
    }

    /// An item's planes: a coded item, a grid of them, or an identity derivation.
    static func planes(of item: HEIFItem, in file: HEIFFile, codec: HEIFCodec, limits: DecodeLimits, depth: Int) throws(ParseFailure) -> HEIFPlanes {
        try checkEssentials(item)
        switch item.type.fourCCString {
        case "hvc1", "av01":
            let p = try decodeCoded(item, codec: codec)
            try limits.checkDimensions(width: p.width, height: p.height, at: 0, rule: "heif.item")
            return withColour(p, item)
        case "grid":
            guard depth == 0 else { throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("nested derivation")) }
            let grid = try HEIFParser.parseGrid(item.data)
            try limits.checkDimensions(width: grid.outputWidth, height: grid.outputHeight, at: 0, rule: "heif.grid")
            let ids = file.references("dimg", from: item.id)
            guard ids.count == grid.rows * grid.columns else {
                throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("\(ids.count) tiles for \(grid.rows)x\(grid.columns)"))
            }
            var tiles: [HEIFItem] = []
            for id in ids {
                guard let t = file.item(id), t.type.fourCCString == (codec == .hevc ? "hvc1" : "av01") else {
                    throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("tile \(id) is not a \(codec) item"))
                }
                try checkEssentials(t)
                tiles.append(t)
            }
            // Every tile has the same size, and together they cover the output exactly once
            // in each direction (23008-12 6.6.2.3.1): checked before anything decodes.
            guard let (tw, th) = tiles[0].spatialExtent, tw > 0, th > 0 else { throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("tile without ispe")) }
            guard tw * grid.columns >= grid.outputWidth, tw * (grid.columns - 1) < grid.outputWidth,
                  th * grid.rows >= grid.outputHeight, th * (grid.rows - 1) < grid.outputHeight else {
                throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("\(tw)x\(th) tiles for \(grid.outputWidth)x\(grid.outputHeight)"))
            }
            let decoded = try decodeTiles(tiles, codec: codec)
            var out = try compose(decoded, grid: grid, tileWidth: tw, tileHeight: th)
            out = withColour(out, tiles[0])
            return withColour(out, item)
        case "iden":
            guard depth == 0, let id = file.references("dimg", from: item.id).first, let src = file.item(id) else {
                throw ParseFailure(offset: 0, rule: "heif.iden", reason: .invalid("no source image"))
            }
            return withColour(try planes(of: src, in: file, codec: codec, limits: limits, depth: depth + 1), item)
        default:
            throw ParseFailure(offset: 0, rule: "heif.item", reason: .invalid("item type \(item.type.fourCCString)"))
        }
    }

    /// An nclx colr on the item wins over what the bitstream says.
    static func withColour(_ p: HEIFPlanes, _ item: HEIFItem) -> HEIFPlanes {
        var p = p
        if case .nclx(let pr, let tr, let m, let f) = item.colour { p.colour = HEIFColourInfo(primaries: pr, transfer: tr, matrix: m, fullRange: f) }
        return p
    }

    static func decodeTiles(_ tiles: [HEIFItem], codec: HEIFCodec) throws(ParseFailure) -> [HEIFPlanes] {
        let results = Mutex<[Result<HEIFPlanes, ParseFailure>?]>(Array(repeating: nil, count: tiles.count))
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let r: Result<HEIFPlanes, ParseFailure>
            do throws(ParseFailure) { r = .success(try decodeCoded(tiles[i], codec: codec)) } catch { r = .failure(error) }
            results.withLock { $0[i] = r }
        }
        var out: [HEIFPlanes] = []
        for r in results.withLock({ $0 }) {
            switch r {
            case .success(let p): out.append(p)
            case .failure(let e): throw e
            case nil: throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("tile not decoded"))
            }
        }
        return out
    }

    static func compose(_ tiles: [HEIFPlanes], grid: HEIFGrid, tileWidth tw: Int, tileHeight th: Int) throws(ParseFailure) -> HEIFPlanes {
        let f = tiles[0]
        for t in tiles where t.width != tw || t.height != th || t.bitDepth != f.bitDepth || t.chromaFormat != f.chromaFormat {
            throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("tiles differ in size or format"))
        }
        guard tw % (1 << f.subsamplingX) == 0, th % (1 << f.subsamplingY) == 0 else {
            throw ParseFailure(offset: 0, rule: "heif.grid", reason: .invalid("tile size \(tw)x\(th) not a multiple of the chroma subsampling"))
        }
        var out = HEIFPlanes(width: grid.outputWidth, height: grid.outputHeight, bitDepth: f.bitDepth, chromaFormat: f.chromaFormat,
                             y: [], u: [], v: [], colour: f.colour)
        out.y = [UInt16](repeating: 0, count: out.width * out.height)
        let cw = out.chromaWidth, ch = out.chromaHeight
        out.u = [UInt16](repeating: 0, count: cw * ch)
        out.v = out.u
        func blit(_ src: [UInt16], _ sw: Int, _ sh: Int, into dst: inout [UInt16], _ dw: Int, _ dh: Int, at x0: Int, _ y0: Int) {
            let w = min(sw, dw - x0), h = min(sh, dh - y0)
            guard w > 0, h > 0 else { return }
            for y in 0..<h { dst.replaceSubrange((y0 + y) * dw + x0 ..< (y0 + y) * dw + x0 + w, with: src[y * sw ..< y * sw + w]) }
        }
        for (i, t) in tiles.enumerated() {
            let r = i / grid.columns, c = i % grid.columns
            blit(t.y, t.width, t.height, into: &out.y, out.width, out.height, at: c * tw, r * th)
            if f.chromaFormat != 0 {
                let x0 = (c * tw) >> f.subsamplingX, y0 = (r * th) >> f.subsamplingY
                blit(t.u, t.chromaWidth, t.chromaHeight, into: &out.u, cw, ch, at: x0, y0)
                blit(t.v, t.chromaWidth, t.chromaHeight, into: &out.v, cw, ch, at: x0, y0)
            }
        }
        return out
    }

    /// One coded image item through its codec.
    static func decodeCoded(_ item: HEIFItem, codec: HEIFCodec) throws(ParseFailure) -> HEIFPlanes {
        let data = item.data
        guard !data.isEmpty else { throw ParseFailure(offset: 0, rule: "heif.item", reason: .invalid("item \(item.id) has no data")) }
        switch codec {
        case .hevc:
            guard item.type == FourCC("hvc1"), let cfg = item.hevcConfiguration else {
                throw ParseFailure(offset: 0, rule: "heif.hvc1", reason: .mismatch(expected: "hvcC"))
            }
            let frame: HEVCFrame
            do {
                let d = try HEVCDecoder(vps: cfg.videoParameterSets.map { $0.copyBytes() }, sps: cfg.sequenceParameterSets.map { $0.copyBytes() },
                                        pps: cfg.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: cfg.nalLengthSize)
                var frames = d.decode(sample: data, pts: 0)
                frames += d.flush()
                guard d.errorCount == 0, let f = frames.first else {
                    throw ParseFailure(offset: 0, rule: "heif.hvc1", reason: .invalid("item \(item.id): undecodable HEVC (\(d.errorCount) errors)"))
                }
                frame = f
            } catch let e as ParseFailure { throw e } catch {
                throw ParseFailure(offset: 0, rule: "heif.hvc1", reason: .invalid("item \(item.id): \(error)"))
            }
            return HEIFPlanes(width: frame.width, height: frame.height, bitDepth: frame.bitDepth, chromaFormat: frame.chromaFormat,
                              y: frame.y, u: frame.u, v: frame.v,
                              colour: HEIFColourInfo(primaries: frame.colourPrimaries, transfer: frame.transferCharacteristics,
                                                     matrix: frame.matrixCoefficients, fullRange: frame.fullRange))
        case .av1:
            guard item.type == FourCC("av01"), let cfg = item.av1Configuration else {
                throw ParseFailure(offset: 0, rule: "heif.av01", reason: .mismatch(expected: "av1C"))
            }
            let f: AV1Frame
            do throws(AV1DecodeError) { f = try AV1Decoder.decodeStill(data, configOBUs: cfg.configOBUs) } catch {
                throw ParseFailure(offset: 0, rule: "heif.av01", reason: .invalid("item \(item.id): \(error)"))
            }
            let cf = f.monochrome ? 0 : (f.subsamplingX && f.subsamplingY ? 1 : (f.subsamplingX ? 2 : 3))
            return HEIFPlanes(width: f.width, height: f.height, bitDepth: f.bitDepth, chromaFormat: cf, y: f.y, u: f.u, v: f.v,
                              colour: HEIFColourInfo(primaries: f.colourPrimaries, transfer: f.transferCharacteristics, matrix: f.matrixCoefficients,
                                                     fullRange: f.fullRange))
        }
    }
}

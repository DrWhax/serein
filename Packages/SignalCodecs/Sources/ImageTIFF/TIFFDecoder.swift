// The classic, strip-based TIFF bitmaps written to the macOS pasteboard by AppKit.
// Read the first image directory only. Its pixels are interleaved unsigned RGB or
// grayscale samples, optionally with alpha. Ignore profiles, thumbnails and metadata.
public import CodecCore

public enum TIFFDecoder {
    private enum Order {
        case little, big

        func short(_ c: inout ByteCursor) throws(ParseFailure) -> Int {
            try Int(self == .little ? c.u16le() : c.u16be())
        }

        func long(_ c: inout ByteCursor) throws(ParseFailure) -> Int {
            try Int(self == .little ? c.u32le() : c.u32be())
        }
    }

    private enum Tag: Int {
        case width = 256, height = 257, bits = 258, compression = 259, photometric = 262, fillOrder = 266
        case offsets = 273, orientation = 274, samples = 277, rows = 278, byteCounts = 279, planar = 284
        case predictor = 317, extraSamples = 338, sampleFormat = 339
    }

    private struct Directory {
        let order: Order
        let input: ByteSlice
        var fields: [Tag: (short: Bool, count: Int, bytes: ByteSlice)] = [:]

        init(_ input: ByteSlice) throws(ParseFailure) {
            self.input = input
            var header = input.cursor()
            switch try header.u16be() {
            case 0x4949: order = .little
            case 0x4d4d: order = .big
            default: throw header.fail("TIFF.byteOrder", .invalid("expected II or MM"))
            }
            guard try order.short(&header) == 42 else { throw header.fail("TIFF.magic", .invalid("expected classic TIFF")) }
            let offset = try order.long(&header)
            var entries = input.cursor()
            try entries.skip(offset)
            let count = try order.short(&entries)
            for _ in 0..<count {
                let tag = Tag(rawValue: try order.short(&entries))
                let type = try order.short(&entries)
                let length = try order.long(&entries)
                let slot = try entries.bytes(4)
                guard let tag else { continue }
                guard fields[tag] == nil, type == 3 || type == 4, length > 0 else {
                    throw entries.fail("TIFF.field", .invalid("duplicate tag or invalid integer field"))
                }
                let size = length * (type == 3 ? 2 : 4)
                var value = slot.cursor()
                if size > 4 {
                    let offset = try order.long(&value)
                    value = input.cursor()
                    try value.skip(offset)
                }
                fields[tag] = (type == 3, length, try value.bytes(size))
            }
            try entries.skip(4, "TIFF.nextIFD")
        }

        // Check the expected number of values before allocating or following strip offsets.
        func values(_ tag: Tag, count: Int) throws(ParseFailure) -> [Int] {
            guard let field = fields[tag], field.count == count else {
                throw input.cursor().fail("TIFF.tag.\(tag)", .invalid("expected \(count) values"))
            }
            var c = field.bytes.cursor()
            var result: [Int] = []
            for _ in 0..<count { result.append(try field.short ? order.short(&c) : order.long(&c)) }
            return result
        }

        func scalar(_ tag: Tag, default fallback: Int? = nil) throws(ParseFailure) -> Int {
            if fields[tag] == nil, let fallback { return fallback }
            return try values(tag, count: 1)[0]
        }
    }

    public static func decode(_ bytes: [UInt8], limits: DecodeLimits = .default) throws(ParseFailure) -> PixelBuffer {
        let input = ByteSlice(bytes)
        let invalid = input.cursor().fail("TIFF.raster", .invalid("unsupported bitmap layout"))
        guard input.count <= limits.maxInputBytes else { throw input.cursor().fail("TIFF", .limitExceeded("input size")) }
        let dir = try Directory(input)
        let width = try dir.scalar(.width), height = try dir.scalar(.height)
        try limits.checkDimensions(width: width, height: height, at: 0, rule: "TIFF.dimensions")
        let photo = try dir.scalar(.photometric), samples = try dir.scalar(.samples, default: 1)
        let colors = photo == 2 ? 3 : 1
        guard (0...2).contains(photo), samples == colors || samples == colors + 1,
              try dir.scalar(.compression, default: 1) == 1, try dir.scalar(.predictor, default: 1) == 1,
              try dir.scalar(.orientation, default: 1) == 1, try dir.scalar(.fillOrder, default: 1) == 1,
              try dir.scalar(.planar, default: 1) == 1 else { throw invalid }
        let bits = try dir.values(.bits, count: samples)
        guard bits[0] == 8 || bits[0] == 16, bits.allSatisfy({ $0 == bits[0] }) else { throw invalid }
        if dir.fields[.sampleFormat] != nil {
            guard try dir.values(.sampleFormat, count: samples).allSatisfy({ $0 == 1 }) else { throw invalid }
        }
        let extra = try dir.scalar(.extraSamples, default: 0)
        guard samples > colors ? (0...2).contains(extra) : extra == 0 else { throw invalid }
        let rows = try dir.scalar(.rows, default: height)
        guard rows > 0 else { throw invalid }
        let stripCount = 1 + (height - 1) / rows
        let offsets = try dir.values(.offsets, count: stripCount)
        let sizes = try dir.values(.byteCounts, count: stripCount)
        let stride = width * samples * (bits[0] / 8)
        // Check all strips before allocating the output image.
        var strips: [ByteSlice] = []
        for strip in 0..<stripCount {
            guard sizes[strip] == stride * min(rows, height - strip * rows) else { throw invalid }
            var cursor = input.cursor()
            try cursor.skip(offsets[strip])
            strips.append(try cursor.bytes(sizes[strip]))
        }

        func sample(_ c: inout ByteCursor) throws(ParseFailure) -> UInt8 {
            if bits[0] == 8 { return try c.u8() }
            return try UInt8(dir.order.short(&c) >> 8)
        }
        func straight(_ value: UInt8, alpha: UInt8) -> UInt8 {
            guard extra == 1, alpha < 255 else { return value }
            guard alpha > 0 else { return 0 }
            return UInt8(clamping: (Int(value) * 255 + Int(alpha) / 2) / Int(alpha))
        }
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for strip in strips {
            var c = strip.cursor()
            while !c.isAtEnd {
                let first = try sample(&c)
                let red = photo == 0 ? 255 - first : first
                let green = try colors == 3 ? sample(&c) : red
                let blue = try colors == 3 ? sample(&c) : red
                let last = try samples > colors ? sample(&c) : 255
                let alpha: UInt8 = extra == 0 ? 255 : last
                rgba.append(straight(red, alpha: alpha))
                rgba.append(straight(green, alpha: alpha))
                rgba.append(straight(blue, alpha: alpha))
                rgba.append(alpha)
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }
}

/// VP9 profile 0, uncompressed header (VP9 Bitstream Specification, section 6.2).
public enum VP9DecodeError: Error { case malformed, unsupported, missingReference }

struct VP9Bits {
    let data: [UInt8]
    var position = 0
    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, count <= 24, position <= data.count * 8 - count else { throw VP9DecodeError.malformed }
        var value = 0
        for _ in 0..<count {
            value = (value << 1) | Int((data[position / 8] >> (7 - position % 8)) & 1)
            position += 1
        }
        return value
    }
    mutating func flag() throws -> Bool { try read(1) != 0 }
    mutating func signed(_ n: Int) throws -> Int { let v = try read(n); return try flag() ? -v : v }
    mutating func optionalDelta(_ n: Int) throws -> Int? { try flag() ? signed(n) : nil }
}

struct VP9Segmentation {
    var absolute = false
    var features = [[Int?]](repeating: .init(repeating: nil, count: 4), count: 8)
    var tree = [Int](repeating: 255, count: 7), prediction = [Int](repeating: 255, count: 3)
}

struct VP9Header {
    var existing: Int?
    var key = false, show = false, resilient = false, intraOnly = false
    var reset = 0, refresh = 0, context = 0, saveContext = false, parallel = true
    var width = 0, height = 0
    var references = [Int](repeating: 0, count: 3), bias = [Bool](repeating: false, count: 4)
    var highPrecision = false, filter = 4
    var level = 0, sharpness = 0, hasFilterDeltas = false
    var refDeltas = [Int?](repeating: nil, count: 4), modeDeltas = [Int?](repeating: nil, count: 2)
    var q = 0, yDC = 0, uvDC = 0, uvAC = 0
    var segmentation = VP9Segmentation(), segmented = false, updateMap = false, temporalMap = false
    var logCols = 0, logRows = 0
    var headerBytes = 0, compressedBytes = 0
    var intra: Bool { key || intraOnly }
    var lossless: Bool { q == 0 && yDC == 0 && uvDC == 0 && uvAC == 0 }

    init(_ data: [UInt8], sizes: [(Int,Int)?], segmentation previous: VP9Segmentation) throws {
        guard data.count <= 8 << 20, sizes.count == 8 else { throw VP9DecodeError.malformed }
        var bits = VP9Bits(data: data)
        guard try bits.read(2) == 2 else { throw VP9DecodeError.malformed }
        guard try bits.read(2) == 0 else { throw VP9DecodeError.unsupported }
        if try bits.flag() { existing = try bits.read(3); return }
        key = try !bits.flag()
        show = try bits.flag()
        resilient = try bits.flag()
        if !key {
            if !show { intraOnly = try bits.flag() }
            reset = resilient ? 0 : try bits.read(2)
        }
        segmentation = intra || resilient ? VP9Segmentation() : previous
        if intra {
            guard try bits.read(24) == 0x498342 else { throw VP9DecodeError.malformed }
            if key {
                guard try bits.read(3) != 7 else { throw VP9DecodeError.malformed }
                _ = try bits.flag() // color range
                refresh = 255
            } else { refresh = try bits.read(8) }
        } else {
            refresh = try bits.read(8)
            for i in 0..<3 { references[i] = try bits.read(3); bias[i+1] = try bits.flag() }
            for slot in references {
                if try bits.flag() {
                    guard let dimensions = sizes[slot] else { throw VP9DecodeError.missingReference }
                    (width,height) = dimensions
                    break
                }
            }
        }
        if width == 0 { width = try bits.read(16) + 1; height = try bits.read(16) + 1 }
        guard width <= 4096, height <= 4096, width*height <= 3840*2160 else { throw VP9DecodeError.unsupported }
        if try bits.flag() { _ = try bits.read(16); _ = try bits.read(16) } // render size
        if !intra {
            highPrecision = try bits.flag()
            filter = try bits.flag() ? 4 : [1,0,2,3][bits.read(2)]
        }
        if !resilient { saveContext = try bits.flag(); parallel = try bits.flag() }
        context = try bits.read(2)
        level = try bits.read(6)
        sharpness = try bits.read(3)
        hasFilterDeltas = try bits.flag()
        if hasFilterDeltas, try bits.flag() {
            for i in refDeltas.indices { refDeltas[i] = try bits.optionalDelta(6) }
            for i in modeDeltas.indices { modeDeltas[i] = try bits.optionalDelta(6) }
        }
        q = try bits.read(8)
        yDC = try bits.optionalDelta(4) ?? 0
        uvDC = try bits.optionalDelta(4) ?? 0
        uvAC = try bits.optionalDelta(4) ?? 0
        segmented = try bits.flag()
        if segmented {
            updateMap = try bits.flag()
            if updateMap {
                for i in 0..<7 { segmentation.tree[i] = try bits.flag() ? bits.read(8) : 255 }
                temporalMap = try bits.flag()
                if temporalMap { for i in 0..<3 { segmentation.prediction[i] = try bits.flag() ? bits.read(8) : 255 } }
            }
            if try bits.flag() {
                segmentation.absolute = try bits.flag()
                for s in 0..<8 { for f in 0..<4 {
                    if try bits.flag() {
                        segmentation.features[s][f] = f < 2 ? try bits.signed([8,6][f]) : try bits.read(f == 2 ? 2 : 0)
                    } else { segmentation.features[s][f] = nil }
                } }
            }
        }
        let sbCols = (width + 63)/64
        while 64 << logCols < sbCols { logCols += 1 }
        var maxCols = 1
        while sbCols >> maxCols >= 4 { maxCols += 1 }
        while logCols < maxCols-1, try bits.flag() { logCols += 1 }
        if try bits.flag() { logRows = try 1 + bits.read(1) }
        compressedBytes = try bits.read(16)
        headerBytes = (bits.position+7)/8
        guard compressedBytes > 0, headerBytes + compressedBytes < data.count else { throw VP9DecodeError.malformed }
    }
}

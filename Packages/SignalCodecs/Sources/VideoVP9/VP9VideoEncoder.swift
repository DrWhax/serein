import Dispatch
import Synchronization

/// Profile-0 VP9 for 8-bit YUV 4:2:0 calls. Key pictures use spatial DC prediction in 8x8
/// blocks with 4x4 transforms. Inter pictures code 16x16 blocks (8x8 where the picture's edge
/// forces it; 32x32 and 64x64 where one vector leaves the residual flat) with motion searched
/// on the reference and coded with the decoder's own vector prediction and 8-tap
/// interpolation, and each block's transform size (4x4 to 16x16) chosen by rate and
/// distortion; a spatial layer predicts its lower layer scaled, with zero motion. Tile columns
/// (up to four) encode in parallel. Frame-parallel error-resilient pictures keep probabilities
/// independent of packet loss.
public struct VP9VideoEncoder: Sendable {
    /// The last coded picture as a decoder holds it, and its blocks (co-located predictors).
    private var reference: [VP9Plane] = []
    private var referenceBlocks: [VP9Block] = []
    /// The source of the last coded picture: identical blocks settle to skips (see refines).
    private var referenceInputs: [[UInt8]] = []
    private var sinceKey = 0

    public init() {}

    /// What a decoder holds after the last picture.
    var reconstruction: [VP9Plane] { reference }

    public mutating func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                quantizer: Int = 72, keyframe: Bool = false) -> [UInt8]? {
        guard (1...4096).contains(width), (1...4096).contains(height), width*height <= 3840*2160,
              y.count == width*height, u.count == ((width+1)/2)*((height+1)/2), v.count == u.count,
              (0...255).contains(quantizer) else { return nil }
        let key = keyframe || sinceKey >= 119 || reference.first?.width != width || reference.first?.height != height
        let result = picture(width:width,height:height,y:y,u:u,v:v,q:quantizer,key:key,independent:false,readSlot:0,writeSlot:0)
        sinceKey = key ? 0 : sinceKey+1
        return result
    }

    fileprivate mutating func picture(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                      q: Int, key: Bool, independent: Bool, readSlot: Int, writeSlot: Int) -> [UInt8] {
        let intra = key || independent
        let scaled = !intra && (reference[0].width != width || reference[0].height != height)
        // Tile columns, as many as the width allows up to four, encode in parallel (and let a
        // receiver decode in parallel); each predicts and codes only within its own columns.
        let sbCols = (width+63)/64, cols = (width+7)/8, rows = (height+7)/8
        var maxLog = 0
        while sbCols >> (maxLog+1) >= 4 { maxLog += 1 }
        let log = min(maxLog, 2), count = 1 << log
        @Sendable func start(_ n: Int) -> Int { min(cols, (((cols+7)/8*n) >> log)*8) }
        let inputs = [y,u,v], references = intra ? [] : reference
        let previous = intra || scaled ? [] : referenceBlocks, previousInputs = intra || scaled ? [] : referenceInputs
        let search = !intra && !scaled ? EncoderTile.searchPlane(reference[0], width: width, height: height) : []
        let results = Mutex<[(payload: [UInt8], recon: [VP9Plane], blocks: [VP9Block])?]>(.init(repeating: nil, count: count))
        DispatchQueue.concurrentPerform(iterations: count) { index in
            var tile = EncoderTile(width:width, height:height, columns:start(index)..<start(index+1), inputs:inputs,
                                   reference:references, previous:previous, previousInputs:previousInputs, search:search,
                                   q:q, key:intra)
            let payload = tile.encode()
            results.withLock { $0[index] = (payload, tile.recon, tile.blocks) }
        }
        let tiles = results.withLock { $0 }.map { $0! }
        var payload: [UInt8] = []
        for (index, tile) in tiles.enumerated() {
            if index < count-1 { for shift in [24,16,8,0] { payload.append(UInt8(truncatingIfNeeded: tile.payload.count >> shift)) } }
            payload += tile.payload
        }
        let compressed = Self.compressedHeader(key:intra,lossless:q == 0,select:!intra && q != 0)
        var raw = EncoderBits()
        raw.write(2,2) // frame marker
        raw.write(0,3) // profile 0, regular coded picture
        raw.write(key ? 0 : 1,1)
        raw.write(independent ? 0 : 1,1) // intra-only pictures are displayed by show_existing_frame
        raw.write(1,1) // error resilient
        if independent { raw.write(1,1) }
        if intra {
            raw.write(0x498342,24)
            if key { raw.write(0,4) } // unspecified colour space, studio range
            else { raw.write(1 << writeSlot,8) }
        } else {
            raw.write(1 << writeSlot,8)
            for _ in 0..<3 { raw.write(readSlot,3); raw.write(0,1) }
            if scaled { raw.write(0,3) } else { raw.write(1,1) }
        }
        if intra || scaled {
            raw.write(width-1,16)
            raw.write(height-1,16)
        }
        raw.write(0,1) // display and coded dimensions match
        if !intra { raw.write(1,4) } // no high precision motion; the regular 8-tap filter for every block
        raw.write(0,2) // frame context
        raw.write(0,10) // loop filter level, sharpness and deltas
        raw.write(q,8)
        raw.write(0,4) // quantizer deltas and segmentation
        for _ in 0..<log { raw.write(1,1) } // tile columns: 1 << log
        if log < maxLog { raw.write(0,1) }
        raw.write(0,1) // single tile row
        raw.write(compressed.count,16)
        reference = count == 1 ? tiles[0].recon : (0..<3).map { p in VP9Plane(strips: tiles.map { $0.recon[p] }) }
        if count == 1 { referenceBlocks = tiles[0].blocks } else {
            referenceBlocks = []
            referenceBlocks.reserveCapacity(cols*rows)
            for row in 0..<rows {
                for (index, tile) in tiles.enumerated() {
                    let span = start(index+1) - start(index)
                    referenceBlocks.append(contentsOf: tile.blocks[(row*span)..<((row+1)*span)])
                }
            }
        }
        referenceInputs = [y,u,v]
        var bytes = raw.bytes + compressed + payload
        if independent {
            // An intra-only enhancement refreshes just its own slot in a shared decoder.
            // This superframe then displays it. A receiver selecting only this spatial
            // stream can start independently at the same access point.
            let size = bytes.count, magnitude = size < 256 ? 1 : size < 65536 ? 2 : 3
            let marker = UInt8(0xc1 | ((magnitude-1) << 3))
            bytes += [0x88 | UInt8(writeSlot), marker]
            for length in [size,1] {
                for i in 0..<magnitude { bytes.append(UInt8(truncatingIfNeeded:length >> (i*8))) }
            }
            bytes.append(marker)
        }
        return bytes
    }

    private static func compressedHeader(key: Bool, lossless: Bool, select: Bool) -> [UInt8] {
        var w = EncoderBoolean()
        if select {
            // TX_MODE_SELECT (3, then 1): each block codes its transform size, with the default
            // transform size probabilities.
            w.literal(3, bits: 2)
            w.put(true)
            for _ in 0..<12 { w.put(false,252) }
        } else if !lossless {
            w.literal(0, bits: 2) // Only 4x4 residual transforms.
        }
        // Keep the default coefficient model of every transform size the picture allows.
        for _ in 0..<(select ? 4 : 1) { w.put(false) }
        for _ in 0..<3 { w.put(false,252) } // Skip probabilities.
        if !key {
            // Inter modes, intra/inter, single reference, luma mode, partition and
            // motion vector probabilities, with fixed interpolation and no high precision.
            for _ in 0..<(21+4+10+36+48+3+2*(1+10+1+10+6+3)) { w.put(false,252) }
        }
        return w.finish()
    }
}

private struct EncoderBits {
    var bytes: [UInt8] = []
    private var bitCount = 0
    mutating func write(_ value: Int, _ width: Int) {
        for i in (0..<width).reversed() {
            if bitCount == 0 { bytes.append(0) }
            bytes[bytes.count-1] |= UInt8((value >> i) & 1) << (7-bitCount)
            bitCount = (bitCount+1) & 7
        }
    }
}

/// One tile column. Coding order, contexts and reconstruction follow the decoder
/// (VP9Tile.partition/block), whose functions it calls for prediction and vector candidates.
private struct EncoderTile {
    typealias Coefficients = InlineArray<16, Int>
    /// One transform block's quantized levels: levels[start ..< start + size*size], raster order.
    struct TransformBlock { let plane, x, y, tx, start, end: Int }
    let width, height, cols, rows: Int
    /// This tile's MI columns.
    let left, right: Int
    let inputs: [[UInt8]]
    let reference: [VP9Plane]
    let previous: [VP9Block]
    let previousInputs: [[UInt8]]
    let q: Int, key: Bool
    /// 4 (TX_MODE_SELECT) on inter pictures; 0 (4x4 only) on key and lossless pictures.
    let txMode: Int
    private(set) var recon: [VP9Plane]
    private(set) var blocks: [VP9Block]
    private var above, leftContext: [Int]
    private var nzAbove, nzLeft: [[UInt8]]
    private var writer = EncoderBoolean()
    private let unscaled: Bool
    /// libvpx sad_per_bit16 for this quantizer: SAD units worth one bit.
    private let lambda: Int
    /// The quantizer steps as reciprocals (DC, then AC).
    private let dcStep: QuantizerStep, acStep: QuantizerStep
    private var scratch = [UInt8](repeating: 0, count: 64*64), source = [UInt8](repeating: 0, count: 64*64)
    /// The superblock being coded: for each 16x16 cell, how far the residual of one shared
    /// whole-sample vector is from flat (sum |r| - |sum r|), which decides larger blocks.
    private var cellDeviation = InlineArray<16, Int>(repeating: 0)
    /// A 32x32 or 64x64 area is one block where every cell deviates less than this (step/16 and
    /// step/64 a sample merged textured noise and cost Mandelbrot and static content 2-22%).
    private let flatCell: Int
    /// The current block's transform blocks and their levels (64x64 luma and chroma at most).
    private var transformBlocks: [TransformBlock] = []
    private var levels = [Int](repeating: 0, count: 3*4096 + 2*32*32)
    /// Lambda for transform-domain squared error per 1/256 bit: 0.2 * step^2 / 256 per bit (the
    /// squared step in coefficients, which are 8x orthonormal).
    private let rateWeight: Int
    /// Dequantized coefficients for the inverse transform (zero between uses).
    private var coefficients = [Int](repeating: 0, count: 32*32)
    /// A residual and its forward transform (8x8 and 16x16 blocks).
    private var residualBuffer = [Float](repeating: 0, count: 256), transformBuffer = [Float](repeating: 0, count: 256)
    private static let noBias = [false,false,false,false]
    /// The reference luma with its edge samples repeated `border` samples out on every side (the
    /// decoder's clamping), so searched positions read it without bounds tests.
    private static let border = 88
    private let search: [UInt8], searchStride: Int

    init(width: Int, height: Int, columns: Range<Int>, inputs: [[UInt8]], reference: [VP9Plane], previous: [VP9Block],
         previousInputs: [[UInt8]], search: [UInt8], q: Int, key: Bool) {
        self.width = width; self.height = height; self.inputs = inputs; self.previousInputs = previousInputs
        left = columns.lowerBound; right = columns.upperBound
        self.reference = reference; self.previous = previous; self.q = q; self.key = key
        txMode = key || q == 0 ? 0 : 4
        cols = (width+7)/8; rows = (height+7)/8
        recon = VP9Picture.planes(width: width, height: height, columns: columns)
        blocks = .init(repeating: .init(), count: (right-left)*rows)
        // Contexts run on to the superblock edge (blocks there may reach past the picture).
        let alignedCols = (cols+7)/8*8, alignedRows = (rows+7)/8*8
        above = .init(repeating: 0, count: alignedCols); leftContext = .init(repeating: 0, count: alignedRows)
        nzAbove = [.init(repeating: 0, count: alignedCols*2), .init(repeating: 0, count: alignedCols), .init(repeating: 0, count: alignedCols)]
        nzLeft = [.init(repeating: 0, count: alignedRows*2), .init(repeating: 0, count: alignedRows), .init(repeating: 0, count: alignedRows)]
        transformBlocks.reserveCapacity(64*64*3/2/16)
        unscaled = !reference.isEmpty && reference[0].width == width && reference[0].height == height
        lambda = max(1, (VP9Table.acQLookup[q] * 1045 + 241_070) / 100_000)
        dcStep = QuantizerStep(VP9Table.dcQLookup[q]); acStep = QuantizerStep(VP9Table.acQLookup[q])
        rateWeight = max(1, VP9Table.acQLookup[q] * VP9Table.acQLookup[q] / 640)
        flatCell = VP9Table.acQLookup[q] // 256 * step / 256: a mean deviation of 1/256 step a sample
        self.search = search; searchStride = unscaled ? width + 2*Self.border : 0
    }

    /// The reference luma with its edge samples repeated `border` samples out on every side.
    static func searchPlane(_ luma: VP9Plane, width: Int, height: Int) -> [UInt8] {
        guard luma.width == width && luma.height == height else { return [] }
        let b = border, stride = width + 2*b
        var plane = [UInt8]()
        plane.reserveCapacity(stride*(height + 2*b))
        for row in 0..<(height + 2*b) {
            let line = min(height-1,max(0,row-b))*luma.stride
            plane.append(contentsOf: repeatElement(luma.bytes[line], count: b))
            plane.append(contentsOf: luma.bytes[line..<(line+width)])
            plane.append(contentsOf: repeatElement(luma.bytes[line+width-1], count: b))
        }
        return plane
    }

    mutating func encode() -> [UInt8] {
        for y in stride(from:0,to:rows,by:8) {
            for x in stride(from:left,to:right,by:8) { partition(x,y,level:3) }
        }
        return writer.finish()
    }

    /// The block at an MI position inside this tile (nothing is read across a tile's edge).
    private func neighbour(_ col: Int, _ row: Int) -> VP9Block? {
        col >= left && col < right && row >= 0 && row < rows ? blocks[row*(right-left)+col-left] : nil
    }

    private mutating func partition(_ x: Int, _ y: Int, level: Int) {
        guard x < right && y < rows else { return }
        let half = (1 << level) / 2
        let hasRows = y+half < rows, hasCols = x+half < cols
        let offset = 3*(level*4 + ((above[x] >> level) & 1) + 2*((leftContext[y] >> level) & 1))
        let probs = key ? VP9Table.kfPartitionProbs : VP9Table.partitionProbs
        if !key && unscaled && level == 3 { analyse(x, y) }
        // PARTITION_NONE: one 16x16 block wherever it fits, and one 32x32 or 64x64 block where
        // the superblock's shared vector leaves every 16x16 cell's residual nearly flat.
        if !key && hasRows && hasCols && (level == 1 || (level > 1 && unscaled && flat(x, y, level))) {
            writer.put(false,probs[offset])
            let size = 1 << level, mask = (16 - 2*size) & 15
            block(x,y,size:size)
            for i in 0..<size { above[x+i] = mask; leftContext[y+i] = mask }
            return
        }
        if hasCols && hasRows { writer.put(level > 0,probs[offset]) }
        if level > 0 {
            if hasCols { writer.put(true,probs[offset+1]) }
            if hasRows { writer.put(true,probs[offset+2]) }
            for yy in [y,y+half] { for xx in [x,x+half] { partition(xx,yy,level:level-1) } }
            return
        }
        block(x,y,size:1)
        above[x] = 14
        leftContext[y] = 14
    }

    /// The superblock at MI (x, y): the best whole-sample vector by SAD among zero and the left,
    /// above and co-located previous blocks' vectors, then each 16x16 cell's deviation from a
    /// flat residual with it.
    private mutating func analyse(_ x: Int, _ y: Int) {
        let px = x*8, py = y*8
        loadSource(px, py, 64)
        var candidates = InlineArray<4, VP9MV>(repeating: VP9MV()), count = 1
        for (col, row, old) in [(x-1, y, false), (x, y-1, false), (x, y, true)] {
            guard col >= 0, row >= 0 else { continue }
            let b = old ? (previous.isEmpty ? nil : previous[row*cols+col]) : neighbour(col, row)
            guard let b, b.refs.0 != 0 else { continue }
            // Whole samples, within 64 of the superblock, which stays within 80 samples outside the
            // picture (the search border is 88; a superblock may reach 56 past the picture).
            let v = b.vectors.0
            let whole = VP9MV(row: max(-512, -(py+80)*8, min(512, (height+16-py)*8, (v.row/8)*8)),
                              col: max(-512, -(px+80)*8, min(512, (width+16-px)*8, (v.col/8)*8)))
            candidates[count] = whole; count += 1
        }
        var best = VP9MV(), bestSAD = Int.max
        for i in 0..<count {
            let s = sad(candidates[i], px, py, 64)
            if s < bestSAD { best = candidates[i]; bestSAD = s }
        }
        let b = Self.border, stride = searchStride
        let origin = ((py + best.row/8) + b)*stride + (px + best.col/8) + b
        let plane = search.span, block = source.span
        for cell in 0..<16 {
            let cx = (cell & 3)*16, cy = (cell >> 2)*16
            var magnitude = Row(repeating: 0), sum = Row(repeating: 0)
            for r in 0..<16 {
                let s = Self.row(block, (cy + r)*64 + cx), p = Self.row(plane, origin + (cy + r)*stride + cx)
                magnitude &+= Self.absoluteDifference(s, p)
                sum &+= s &- p
            }
            // Per lane the signed sum stays within 16 * 255: as Int16 it is exact.
            let signed = SIMD16<Int32>(truncatingIfNeeded: SIMD16<Int16>(truncatingIfNeeded: sum)).wrappedSum()
            cellDeviation[cell] = Int(SIMD16<UInt32>(truncatingIfNeeded: magnitude).wrappedSum()) - abs(Int(signed))
        }
    }

    /// Whether every 16x16 cell of the 32x32 or 64x64 area at MI (x, y) inside the picture is flat.
    private func flat(_ x: Int, _ y: Int, _ level: Int) -> Bool {
        let cells = 1 << (level - 1), cx = (x & 7)/2, cy = (y & 7)/2
        for j in 0..<cells where (y + 2*j) < rows {
            for i in 0..<cells where (x + 2*i) < cols && cellDeviation[(cy + j)*4 + cx + i] >= flatCell { return false }
        }
        return true
    }

    /// A block of size x size MIs at (col, row).
    private mutating func block(_ col: Int, _ row: Int, size: Int) {
        let n = size*8
        var b = VP9Block(width: n, height: n)
        b.originX = col*8; b.originY = row*8
        let aboveBlock = neighbour(col,row-1), leftBlock = neighbour(col-1,row)
        let skipContext = (aboveBlock?.skip == true ? 1 : 0) + (leftBlock?.skip == true ? 1 : 0)
        if key {
            writer.put(false,VP9Table.skipProbs[skipContext])
            writer.put(false,VP9Table.KFYModeProbs[0]) // DC_PRED, both neighbours DC
            writer.put(false,VP9Table.KFUVModeProbs[0])
            for p in 0..<3 {
                let shift = p == 0 ? 0 : 1, span = n >> shift
                for dy in stride(from:0,to:span,by:4) {
                    for dx in stride(from:0,to:span,by:4) {
                        let x = ((col*8) >> shift)+dx, y = ((row*8) >> shift)+dy
                        recon[p].predictIntra(mode:0,x:x,y:y,size:4,tileLeft:(left*8) >> shift,tileTop:0,haveRight:dx+4 < span)
                        code(quantizeTransform(p,x,y,tx:0,start:0).block,inter:false)
                    }
                }
            }
        } else {
            let offsets = VP9VectorPrediction.offsets(width: n, height: n)
            let candidates = VP9VectorPrediction.candidates(col: col, row: row, block: b, reference: 1, sub: -1, near: true,
                                                            offsets: offsets, bias: Self.noBias, rows: rows, cols: cols,
                                                            previous: nil) { neighbour($0,$1) }
            let nearest = VP9VectorPrediction.lowerPrecision(candidates[0], highPrecision: false)
            let near = VP9VectorPrediction.lowerPrecision(candidates[1], highPrecision: false)
            let context = VP9VectorPrediction.modeContext(col: col, row: row, offsets: offsets) { neighbour($0,$1) }
            var choice = (mode: 2, mv: VP9MV()) // ZEROMV (a scaled lower layer, or no better vector)
            // An unchanged block is still searched: at coarse quantizers another position (often
            // a fraction, whose filter smooths) can predict it better than its own reconstruction.
            let still = unscaled && unchanged(col, row, n)
            if unscaled { choice = chooseMotion(col, row, n, nearest: nearest, near: near, context: context) }
            b.refs = (1,0); b.motionMode = choice.mode; b.vectors = (choice.mv, VP9MV()); b.filter = 0
            for p in 0..<3 { predict(p, col, row, n, choice.mv) }
            let maxTX = min(3, n.trailingZeroBitCount - 2)
            // The transform size's context (VP9Tile.block): from the neighbours' sizes, a skipped
            // neighbour counting as maxTX.
            let aboveTX = aboveBlock.map { $0.skip ? maxTX : $0.tx }, leftTX = leftBlock.map { $0.skip ? maxTX : $0.tx }
            let txContext = (aboveTX ?? leftTX ?? maxTX) + (leftTX ?? aboveTX ?? maxTX) > maxTX ? 1 : 0
            let txOffset = (maxTX == 1 ? VP9Prob.tx8 : maxTX == 2 ? VP9Prob.tx16 : VP9Prob.tx32) + txContext*maxTX
            // Quantize every transform block first: a block whose coefficients all quantize
            // to zero is coded as skipped (the decoder infers the same skip context).
            let tx = quantizeBlock(col, row, n, maxTX: maxTX, txOffset: txOffset)
            var skip = !transformBlocks.contains { $0.end > 0 }
            // An unchanged block's residual refines what the decoder holds; once it no longer
            // lowers the error (quantization can cycle between near-equal pictures), the block is
            // skipped, so a still picture settles to skips.
            if still && !skip && !refines(col, row, n) { skip = true }
            writer.put(skip,VP9Table.skipProbs[skipContext])
            let a = aboveBlock.map { $0.refs.0 == 0 }, l = leftBlock.map { $0.refs.0 == 0 }
            let interContext: Int
            if let a, let l { interContext = a && l ? 3 : (a || l ? 1 : 0) } else { interContext = (a ?? l) == true ? 2 : 0 }
            writer.put(true,VP9Table.isInterProbs[interContext])
            if txMode == 4 && !skip && maxTX > 0 {
                // The transform size: unary below maxTX.
                for t in 0..<min(tx+1, maxTX) { writer.put(t < tx, VP9Prob.initial[txOffset+t]) }
            }
            writer.put(false,VP9Table.singleRefProbs[VP9References(aboveBlock,leftBlock,bias:Self.noBias).single(1)*2]) // LAST
            writer.interMode(choice.mode, context: context)
            if choice.mode == 3 { writer.motionVector(row: choice.mv.row-nearest.row, col: choice.mv.col-nearest.col) }
            if skip {
                for p in 0..<3 {
                    let shift = p == 0 ? 0 : 1, units = (n >> shift)/4
                    for i in 0..<units { nzAbove[p][(((col*8) >> shift)/4)+i] = 0; nzLeft[p][(((row*8) >> shift)/4)+i] = 0 }
                }
            } else {
                for block in transformBlocks { code(block, inter: true) }
            }
            b.skip = skip
            b.tx = skip ? (txMode == 4 ? maxTX : 0) : tx
        }
        for y in row..<min(rows,row+size) { for x in col..<min(right,col+size) { blocks[y*(right-left)+x-left] = b } }
    }

    /// Adds a transform block's dequantized residual to recon, as the decoder does (VP9Tile.block:
    /// a block with only its DC level through dcOnly).
    private mutating func reconstruct(_ t: TransformBlock) {
        guard t.end > 0 else { return }
        let size = 4 << t.tx, dc = dcStep.step, ac = acStep.step
        if t.end == 1 && q != 0 {
            let value = Int(Int16(truncatingIfNeeded: levels[t.start] * dc))
            recon[t.plane].addConstant(VP9Transform.dcOnly(value, size: size), x: t.x, y: t.y, size: size)
            return
        }
        for i in 0..<(size*size) { coefficients[i] = Int(Int16(truncatingIfNeeded: levels[t.start+i] * (i == 0 ? dc : ac))) }
        VP9Transform.apply(&coefficients, size: size, type: 0, lossless: q == 0)
        recon[t.plane].addResidual(&coefficients, x: t.x, y: t.y, size: size)
    }

    /// Whether the quantized residual lowers the block's squared error against the source. recon
    /// holds the prediction before and after (the residual is applied, measured and undone).
    private mutating func refines(_ col: Int, _ row: Int, _ n: Int) -> Bool {
        var saved: [UInt8] = []
        saved.reserveCapacity(n*n*3/2)
        var before = 0
        for p in 0..<3 {
            let shift = p == 0 ? 0 : 1, y = (row*8) >> shift, size = n >> shift, stride = recon[p].stride
            let x = ((col*8) >> shift) - recon[p].originX
            for r in 0..<size { saved.append(contentsOf: recon[p].bytes[((y+r)*stride + x)..<((y+r)*stride + x + size)]) }
            before += error(p, (col*8) >> shift, y, size)
        }
        var after = 0
        for block in transformBlocks { reconstruct(block) }
        for p in 0..<3 {
            let shift = p == 0 ? 0 : 1
            after += error(p, (col*8) >> shift, (row*8) >> shift, n >> shift)
        }
        var at = 0
        for p in 0..<3 {
            let shift = p == 0 ? 0 : 1, y = (row*8) >> shift, size = n >> shift, stride = recon[p].stride
            let x = ((col*8) >> shift) - recon[p].originX
            for r in 0..<size {
                for c in 0..<size { recon[p].bytes[(y+r)*stride + x + c] = saved[at]; at += 1 }
            }
        }
        return after < before
    }

    /// Squared error of recon against the source over a size x size area of plane p (inside the picture).
    private func error(_ p: Int, _ x: Int, _ y: Int, _ size: Int) -> Int {
        let w = p == 0 ? width : (width+1)/2, h = p == 0 ? height : (height+1)/2, input = inputs[p], plane = recon[p]
        var total = 0
        for r in 0..<max(0, min(size, h-y)) {
            for c in 0..<max(0, min(size, w-x)) {
                let d = Int(plane.bytes[(y+r)*plane.stride + x - plane.originX + c]) - Int(input[(y+r)*w + x + c])
                total += d*d
            }
        }
        return total
    }

    /// The block's source samples are exactly the last coded picture's.
    private func unchanged(_ col: Int, _ row: Int, _ n: Int) -> Bool {
        guard previousInputs.count == 3 else { return false }
        for p in 0..<3 {
            let shift = p == 0 ? 0 : 1, w = p == 0 ? width : (width+1)/2, h = p == 0 ? height : (height+1)/2
            let x = (col*8) >> shift, size = n >> shift, count = min(x+size, w) - x, input = inputs[p], old = previousInputs[p]
            guard x < w else { continue }
            let now = input.span, before = old.span
            for line in ((row*8) >> shift)..<min(((row*8) >> shift)+size, h) where !isZero(sampleDifference(now, before, line*w + x, count)) {
                return false
            }
        }
        return true
    }

    /// The decoder's prediction of plane p for the block (VP9Tile.predictInter).
    private mutating func predict(_ p: Int, _ col: Int, _ row: Int, _ n: Int, _ mv: VP9MV) {
        let shift = p == 0 ? 0 : 1, w = n >> shift
        let at = VP9Plane.motionSource(frame:(width,height),reference:(reference[0].width,reference[0].height),cols:cols,rows:rows,
                                       subsampling:shift,col:col,row:row,blockWidth:w,blockHeight:w,bx:0,by:0,width:w,height:w,mv:mv)
        recon[p].predictInter(reference:reference[p],x:at.x,y:at.y,width:w,height:w,sourceX16:at.x16,sourceY16:at.y16,
                              stepX16:at.stepX16,stepY16:at.stepY16,filter:0)
    }

    /// The input (edge samples repeated) minus what recon holds there: the prediction.
    private func quantize(_ p: Int, _ x: Int, _ y: Int) -> (values: Coefficients, end: Int, error: Int) {
        let w = p == 0 ? width : (width+1)/2, h = p == 0 ? height : (height+1)/2
        let source = inputs[p], prediction = recon[p].bytes, stride = recon[p].stride, origin = recon[p].originX
        let input = source.span, predicted = prediction.span
        var values = Coefficients(repeating: 0)
        var magnitude = 0, energy = 0
        let inside = x + 4 <= w && y + 4 <= h
        for r in 0..<4 {
            let row = min(h-1,y+r)*w, at = (y+r)*stride + x - origin
            for c in 0..<4 {
                let sample = inside ? input[row + x + c] : input[row + min(w-1,x+c)]
                let d = Int(sample) &- Int(predicted[at + c])
                values[r*4+c] = d
                magnitude &+= d < 0 ? 0 &- d : d
                energy &+= d &* d
            }
        }
        // Each pass of the forward 4-point transform at most scales a sum of magnitudes by
        // 15137/16384; with the x16 input scale and the final >> 2 a coefficient stays below
        // 3.42 * magnitude + 1, so below half the smaller step every level is zero.
        guard magnitude*4 + 2 >= min(dcStep.step, acStep.step)/2 else {
            return (Coefficients(repeating: 0), 0, 64*energy)
        }
        Self.forward(&values, lossless: q == 0)
        var error = 0
        for i in 0..<16 {
            let value = values[i], step = i == 0 ? dcStep : acStep, level = step.quantize(value)
            let d = value - level*step.step
            error &+= d &* d
            values[i] = level
        }
        // The scan position after the last nonzero level.
        let scan: InlineArray<16, Int> = [0, 4, 1, 5, 8, 2, 12, 9, 3, 6, 13, 10, 7, 14, 11, 15]
        var end = 16
        while end > 0 && values[scan[end-1]] == 0 { end -= 1 }
        return (values, end, error)
    }

    /// Write a transform block's tokens and add its residual to recon, as the decoder does: the
    /// token context is whether any neighbour 4x4 above or left across the transform's width has
    /// levels, and afterwards those inside the picture take this block's.
    private mutating func code(_ t: TransformBlock, inter: Bool) {
        let p = t.plane, span = 1 << t.tx, ix = t.x/4, iy = t.y/4
        var a = false, l = false
        for i in 0..<span { a = a || nzAbove[p][ix+i] != 0; l = l || nzLeft[p][iy+i] != 0 }
        writer.residual(levels, start: t.start, tx: t.tx, end: t.end, chroma: p != 0, inter: inter, context: (a ? 1 : 0)+(l ? 1 : 0))
        reconstruct(t)
        let shift = p == 0 ? 0 : 1, limitX = (cols*2) >> shift, limitY = (rows*2) >> shift
        for i in 0..<span {
            nzAbove[p][ix+i] = t.end > 0 && ix+i < limitX ? 1 : 0
            nzLeft[p][iy+i] = t.end > 0 && iy+i < limitY ? 1 : 0
        }
    }

    /// Every transform block of an inter block, in the decoder's order (planes, then rows of
    /// transform blocks), and the luma transform size. Blocks starting past the picture's last
    /// 8x8 column or row are not coded; chroma takes the luma size where it fits.
    ///
    /// The size is the candidate (4x4 up to 16x16) of least distortion + lambda * bits. The
    /// distortion is taken in the transform domain: VP9's transforms are 8x orthonormal, so the
    /// coefficients' squared error is 64x the samples'. The bits are the tokens' at the default
    /// probabilities, with the nonzero contexts followed inside the block, plus the size's own.
    private mutating func quantizeBlock(_ col: Int, _ row: Int, _ n: Int, maxTX: Int, txOffset: Int) -> Int {
        transformBlocks.removeAll(keepingCapacity: true)
        let largest = txMode == 4 ? min(maxTX, 2) : 0
        let x0 = col*8, y0 = row*8, units = n/4
        let limitX = cols*8, limitY = rows*8
        var best = (tx: 0, cost: Int.max, first: 0, count: 0)
        // The largest first: when nothing of it survives quantization the block costs almost
        // nothing to code, and a smaller transform cannot save enough to pay its levels.
        let candidates: InlineArray<3, Int> = [largest, 0, largest == 2 ? 1 : -1]
        for candidate in 0..<3 {
            let tx = candidates[candidate]
            if tx < 0 || (candidate > 0 && tx == largest) { continue }
            if candidate > 0 && best.tx == largest && !transformBlocks[best.first..<(best.first+best.count)].contains(where: { $0.end > 0 }) { break }
            let size = 4 << tx, span = 1 << tx, first = transformBlocks.count
            // The neighbours' nonzero flags as the decoder will see them, followed inside the block.
            var aboveNZ = InlineArray<16, Bool>(repeating: false), leftNZ = InlineArray<16, Bool>(repeating: false)
            for i in 0..<units { aboveNZ[i] = nzAbove[0][x0/4+i] != 0; leftNZ[i] = nzLeft[0][y0/4+i] != 0 }
            var distortion = 0, bits = 0, start = tx*4096
            for dy in stride(from:0,to:n,by:size) {
                guard y0+dy < limitY else { break }
                for dx in stride(from:0,to:n,by:size) {
                    guard x0+dx < limitX else { break }
                    let (block, error) = quantizeTransform(0, x0+dx, y0+dy, tx: tx, start: start)
                    transformBlocks.append(block)
                    start += size*size
                    distortion += error
                    let bx = dx/4, by = dy/4
                    var a = false, l = false
                    for i in 0..<span { a = a || aboveNZ[bx+i]; l = l || leftNZ[by+i] }
                    bits += writer.residualBits(levels, start: block.start, tx: tx, end: block.end, chroma: false, inter: true,
                                                context: (a ? 1 : 0)+(l ? 1 : 0))
                    for i in 0..<span { aboveNZ[bx+i] = block.end > 0; leftNZ[by+i] = block.end > 0 }
                }
            }
            if largest > 0 { for t in 0..<min(tx+1, maxTX) { bits += EncoderBoolean.cost(t < tx, VP9Prob.initial[txOffset+t]) } }
            let cost = distortion + rateWeight*bits
            if cost < best.cost { best = (tx, cost, first, transformBlocks.count - first) }
        }
        if best.first > 0 || best.count < transformBlocks.count {
            transformBlocks.removeSubrange((best.first+best.count)...)
            transformBlocks.removeSubrange(0..<best.first)
        }
        var start = 3*4096
        for p in 1..<3 {
            let span = n >> 1, planeTX = min(best.tx, span.trailingZeroBitCount - 2), size = 4 << planeTX
            for dy in stride(from:0,to:span,by:size) {
                let y = ((row*8) >> 1)+dy
                guard y < limitY >> 1 else { break }
                for dx in stride(from:0,to:span,by:size) {
                    let x = ((col*8) >> 1)+dx
                    guard x < limitX >> 1 else { break }
                    transformBlocks.append(quantizeTransform(p, x, y, tx: planeTX, start: start).block)
                    start += size*size
                }
            }
        }
        return best.tx
    }

    /// Plane p's transform block at (x, y): the input (edge samples repeated) minus what recon
    /// holds there (the prediction), transformed and quantized into levels from start.
    private mutating func quantizeTransform(_ p: Int, _ x: Int, _ y: Int, tx: Int, start: Int) -> (block: TransformBlock, error: Int) {
        if tx == 0 {
            let (values, end, error) = quantize(p, x, y)
            var out = levels.mutableSpan
            for i in 0..<16 { out[start+i] = values[i] }
            return (TransformBlock(plane: p, x: x, y: y, tx: 0, start: start, end: end), error)
        }
        let size = 4 << tx
        let w = p == 0 ? width : (width+1)/2, h = p == 0 ? height : (height+1)/2
        let source = inputs[p], prediction = recon[p].bytes, stride = recon[p].stride, origin = recon[p].originX
        var magnitude = 0, energy = 0
        do {
            let input = source.span, predicted = prediction.span
            var residual = residualBuffer.mutableSpan
            // One range check for each run (element checks inside a loop cost more than the work).
            precondition(size*size <= residual.count)
            let inside = x + size <= w && y + size <= h
            for r in 0..<size {
                let line = min(h-1, y+r)*w, at = (y+r)*stride + x - origin
                if inside {
                    let source = input.extracting((line + x)..<(line + x + size)), guess = predicted.extracting(at..<(at + size))
                    for c in 0..<size {
                        let d = Int(source[c]) &- Int(guess[c])
                        residual[r*size + c] = Float(d)
                        magnitude &+= d < 0 ? 0 &- d : d
                        energy &+= d &* d
                    }
                } else {
                    for c in 0..<size {
                        let d = Int(input[line + min(w-1, x+c)]) &- Int(predicted[at + c])
                        residual[r*size + c] = Float(d)
                        magnitude &+= d < 0 ? 0 &- d : d
                        energy &+= d &* d
                    }
                }
            }
        }
        do {
            var out = levels.mutableSpan
            for i in 0..<(size*size) { out[start+i] = 0 }
        }
        // A coefficient (8x the orthonormal DCT) is at most (16 / size) * magnitude: below the
        // smaller step minus half a step, every level is zero.
        let zero = min(dcStep.step - dcStep.half, acStep.step - acStep.half)
        if magnitude*16 + size < zero*size { return (TransformBlock(plane: p, x: x, y: y, tx: tx, start: start, end: 0), 64*energy) }
        // The buffers leave self while spans of them are held (an access to self would overlap).
        var transformed = transformBuffer, stored = levels
        transformBuffer = []; levels = []
        do {
            var out = transformed.mutableSpan
            if size == 8 { Self.forwardDCT8(residualBuffer.span, &out) } else { Self.forwardDCT16(residualBuffer.span, &out) }
        }
        let dc = dcStep, ac = acStep
        let dcInverse = 1 / Float(dc.step), acInverse = 1 / Float(ac.step)
        var error: Float = 0, end = size*size
        do {
            let coefficients = transformed.span
            var out = stored.mutableSpan
            precondition(start >= 0 && start + size*size <= out.count && size*size <= coefficients.count)
            // DC, then the AC coefficients with four error sums (one sum's add latency bound the loop).
            let first = coefficients[0], firstLevel = Int((abs(first) + Float(dc.half)) * dcInverse)
            let firstError = abs(first) - Float(firstLevel)*Float(dc.step)
            out[start] = first < 0 ? -firstLevel : firstLevel
            let step = Float(ac.step), half = Float(ac.half)
            // Four sums with constant offsets (a lane written by a variable index goes through memory).
            var e0 = firstError*firstError, e1: Float = 0, e2: Float = 0, e3: Float = 0
            do {
                let value = coefficients[1], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                out[start+1] = value < 0 ? -level : level
                let d = magnitude - Float(level)*step
                e1 += d*d
            }
            do {
                let value = coefficients[2], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                out[start+2] = value < 0 ? -level : level
                let d = magnitude - Float(level)*step
                e2 += d*d
            }
            do {
                let value = coefficients[3], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                out[start+3] = value < 0 ? -level : level
                let d = magnitude - Float(level)*step
                e3 += d*d
            }
            for i in Swift.stride(from: 4, to: size*size, by: 4) {
                do {
                    let value = coefficients[i], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                    out[start+i] = value < 0 ? -level : level
                    let d = magnitude - Float(level)*step
                    e0 += d*d
                }
                do {
                    let value = coefficients[i+1], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                    out[start+i+1] = value < 0 ? -level : level
                    let d = magnitude - Float(level)*step
                    e1 += d*d
                }
                do {
                    let value = coefficients[i+2], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                    out[start+i+2] = value < 0 ? -level : level
                    let d = magnitude - Float(level)*step
                    e2 += d*d
                }
                do {
                    let value = coefficients[i+3], magnitude = abs(value), level = Int((magnitude + half) * acInverse)
                    out[start+i+3] = value < 0 ? -level : level
                    let d = magnitude - Float(level)*step
                    e3 += d*d
                }
            }
            error = (e0 + e1) + (e2 + e3)
            let scan = size == 8 ? VP9Table.defaultScan8x8 : VP9Table.defaultScan16x16
            while end > 0 && out[start + scan[end-1]] == 0 { end -= 1 }
        }
        transformBuffer = transformed; levels = stored
        return (TransformBlock(plane: p, x: x, y: y, tx: tx, start: start, end: end), Int(error))
    }

    // MARK: Motion

    /// The bits (in 1/256) of coding a bit with an 8-bit probability: -log2(p/256), and of a one
    /// with 256-p. Used to weigh modes and vectors.
    static let bitCost: [Int] = [
        4096, 2048, 1792, 1642, 1536, 1454, 1386, 1329, 1280, 1236, 1198, 1162, 1130, 1101, 1073, 1048, 1024, 1002, 980, 961,
        942, 924, 906, 890, 874, 859, 845, 831, 817, 804, 792, 780, 768, 757, 746, 735, 724, 714, 705, 695,
        686, 676, 668, 659, 650, 642, 634, 626, 618, 611, 603, 596, 589, 582, 575, 568, 561, 555, 548, 542,
        536, 530, 524, 518, 512, 506, 501, 495, 490, 484, 479, 474, 468, 463, 458, 453, 449, 444, 439, 434,
        430, 425, 420, 416, 412, 407, 403, 399, 394, 390, 386, 382, 378, 374, 370, 366, 362, 358, 355, 351,
        347, 343, 340, 336, 333, 329, 326, 322, 319, 315, 312, 309, 305, 302, 299, 296, 292, 289, 286, 283,
        280, 277, 274, 271, 268, 265, 262, 259, 256, 253, 250, 247, 245, 242, 239, 236, 234, 231, 228, 226,
        223, 220, 218, 215, 212, 210, 207, 205, 202, 200, 197, 195, 193, 190, 188, 185, 183, 181, 178, 176,
        174, 171, 169, 167, 164, 162, 160, 158, 156, 153, 151, 149, 147, 145, 143, 140, 138, 136, 134, 132,
        130, 128, 126, 124, 122, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 101, 99, 97, 95, 93,
        91, 89, 87, 86, 84, 82, 80, 78, 77, 75, 73, 71, 70, 68, 66, 64, 63, 61, 59, 58,
        56, 54, 53, 51, 49, 48, 46, 44, 43, 41, 40, 38, 36, 35, 33, 32, 30, 28, 27, 25,
        24, 22, 21, 19, 18, 16, 15, 13, 12, 10, 9, 7, 6, 4, 3, 1, 0
    ]

    private typealias Row = SIMD16<UInt16>

    /// |a - b| per lane for samples below 32 768, in vector operations only (pointwiseMax and
    /// pointwiseMin stay out-of-line calls in the SAD loops).
    @inline(__always)
    private static func absoluteDifference(_ a: Row, _ b: Row) -> Row {
        let d = a &- b, negative = Row(repeating: 0) &- (d &>> Row(repeating: 15))
        return (d ^ negative) &- negative
    }

    /// Sixteen samples from i (16-bit lanes: a 16x16 block's sums per lane stay below 4096).
    @inline(__always)
    private static func row(_ s: borrowing Span<UInt8>, _ i: Int) -> Row {
        // One check for the run (sixteen element checks cost more than the load).
        let w = s.extracting(i..<(i &+ 16))
        return Row(UInt16(w[0]), UInt16(w[1]), UInt16(w[2]), UInt16(w[3]), UInt16(w[4]), UInt16(w[5]), UInt16(w[6]), UInt16(w[7]),
                   UInt16(w[8]), UInt16(w[9]), UInt16(w[10]), UInt16(w[11]), UInt16(w[12]), UInt16(w[13]), UInt16(w[14]), UInt16(w[15]))
    }

    /// The luma SAD of the n x n block at (x, y) predicted with `mv` (eighth samples): read from
    /// the edge-extended reference, with the bilinear filter at fractional positions (libvpx's
    /// realtime search does the same, USE_2_TAPS; finalists are measured exactly). 16x16 blocks
    /// take a row per vector step; 8x8 blocks (picture edges) are measured sample by sample.
    private func sad(_ mv: VP9MV, _ x: Int, _ y: Int, _ n: Int) -> Int {
        let sx = x*16 + mv.col*2, sy = y*16 + mv.row*2, b = Self.border, stride = searchStride
        let origin = ((sy >> 4) + b)*stride + (sx >> 4) + b
        let plane = search.span, block = source.span
        let fx = sx & 15, fy = sy & 15
        if n >= 16 {
            // 16-wide strips; a strip's per-lane sum stays below n * 255 (16 320 at most).
            var all = SIMD16<UInt32>(repeating: 0)
            let w00 = Row(repeating: UInt16((16-fx)*(16-fy))), w01 = Row(repeating: UInt16(fx*(16-fy)))
            let w10 = Row(repeating: UInt16((16-fx)*fy)), w11 = Row(repeating: UInt16(fx*fy))
            let half = Row(repeating: 128), eight = Row(repeating: 8)
            for strip in Swift.stride(from: 0, to: n, by: 16) {
                var total = Row(repeating: 0)
                if fx == 0 && fy == 0 {
                    for r in 0..<n {
                        let p = Self.row(plane, origin &+ r &* stride &+ strip), s = Self.row(block, r &* n &+ strip)
                        total &+= Self.absoluteDifference(p, s)
                    }
                } else {
                    // Bilinear weights sum to 256: a weighted sample stays below 65 536.
                    for r in 0..<n {
                        let i = origin &+ r &* stride &+ strip
                        let p = (Self.row(plane, i) &* w00 &+ Self.row(plane, i &+ 1) &* w01 &+ Self.row(plane, i &+ stride) &* w10
                                 &+ Self.row(plane, i &+ stride &+ 1) &* w11 &+ half) &>> eight
                        let s = Self.row(block, r &* n &+ strip)
                        total &+= Self.absoluteDifference(p, s)
                    }
                }
                all &+= SIMD16<UInt32>(truncatingIfNeeded: total)
            }
            return Int(all.wrappedSum())
        }
        var total = 0
        if fx == 0 && fy == 0 {
            for r in 0..<n {
                let a = origin + r*stride, s = r*n
                for c in 0..<n { total &+= abs(Int(plane[a &+ c]) &- Int(block[s &+ c])) }
            }
            return total
        }
        let w00 = (16-fx)*(16-fy), w01 = fx*(16-fy), w10 = (16-fx)*fy, w11 = fx*fy
        for r in 0..<n {
            let a = origin + r*stride, s = r*n
            for c in 0..<n {
                let i = a &+ c
                let value = (Int(plane[i])*w00 &+ Int(plane[i &+ 1])*w01 &+ Int(plane[i &+ stride])*w10
                             &+ Int(plane[i &+ stride &+ 1])*w11 &+ 128) >> 8
                total &+= abs(value &- Int(block[s &+ c]))
            }
        }
        return total
    }

    /// The exact SAD (the decoder's 8-tap prediction) where `sad` estimates a fractional one.
    private mutating func exactSad(_ mv: VP9MV, _ x: Int, _ y: Int, _ n: Int) -> Int {
        let sx = x*16 + mv.col*2, sy = y*16 + mv.row*2
        guard sx & 15 != 0 || sy & 15 != 0 else { return sad(mv, x, y, n) }
        let b = Self.border, origin = ((sy >> 4) + b)*searchStride + (sx >> 4) + b
        VP9Plane.convolveBlock(search.span, origin: origin, stride: searchStride, width: n, height: n,
                               fractionX: sx & 15, fractionY: sy & 15, filter: 0, into: &scratch)
        let predicted = scratch.span, block = source.span
        var total = 0
        for i in 0..<(n*n) { total &+= abs(Int(predicted[i]) &- Int(block[i])) }
        return total
    }

    private mutating func loadSource(_ x: Int, _ y: Int, _ n: Int) {
        let input = inputs[0], width = width, height = height, inside = x + n <= width && y + n <= height
        let samples = input.span
        var out = source.mutableSpan
        for r in 0..<n {
            let line = min(height-1,y+r)*width
            if inside { for c in 0..<n { out[r*n+c] = samples[line+x+c] } }
            else { for c in 0..<n { out[r*n+c] = samples[line+min(width-1,x+c)] } }
        }
    }

    /// The mode and vector with the lowest luma SAD + lambda * bits. NEW is searched: from the
    /// candidate vectors and the co-located vector of the previous picture, a diamond search
    /// in whole samples (wide steps only when no candidate predicts well), then half- and
    /// quarter-sample refinement with the 8-tap filter.
    private mutating func chooseMotion(_ col: Int, _ row: Int, _ n: Int, nearest: VP9MV, near: VP9MV, context: Int) -> (mode: Int, mv: VP9MV) {
        let x = col*8, y = row*8
        loadSource(x, y, n)
        let modeBits = EncoderBoolean.interModeBits(context: context)
        // Positions already measured for this block (vectors packed in 32 bits).
        var seen = InlineArray<64, (key: Int, sad: Int)>(repeating: (Int.min, 0)), seenCount = 0
        func measure(_ mv: VP9MV) -> Int {
            let key = mv.row << 32 | (mv.col & 0xffff_ffff)
            for i in 0..<min(seenCount, 64) where seen[i].key == key { return seen[i].sad }
            let value = sad(mv, x, y, n)
            seen[seenCount % 64] = (key, value); seenCount += 1
            return value
        }
        func cost(_ mode: Int, _ mv: VP9MV) -> Int {
            var bits = modeBits[mode]
            if mode == 3 { bits += EncoderBoolean.motionVectorBits(row: mv.row-nearest.row, col: mv.col-nearest.col) }
            return measure(mv)*256 + lambda*bits
        }
        var best = (mode: 2, mv: VP9MV(), cost: cost(2, VP9MV()))
        if measure(VP9MV()) == 0 { return (2, VP9MV()) }
        for (mode, mv) in [(0, nearest), (1, near)] {
            let c = cost(mode, mv)
            if c < best.cost { best = (mode, mv, c) }
        }
        // Within 64 samples of the block (repeating texture far away would make the vector field
        // chaotic), and the block within 80 samples outside the picture (the search border is 88,
        // with the filter's taps); the decoder accepts components below 16383 eighth samples, and
        // a difference from the nearest vector codes up to that (class 10).
        func clampVector(_ mv: VP9MV) -> VP9MV {
            func bound(_ v: Int, _ low: Int, _ high: Int, _ base: Int) -> Int {
                max(max(low, -512, base - 16_000), min(min(high, 512, base + 16_000), v))
            }
            return VP9MV(row: bound(mv.row, -(y+80)*8, (height+80-n-y)*8, nearest.row),
                         col: bound(mv.col, -(x+80)*8, (width+80-n-x)*8, nearest.col))
        }
        var center = clampVector(VP9MV(row: (best.mv.row/8)*8, col: (best.mv.col/8)*8)), centerCost = cost(3, center)
        if !previous.isEmpty, previous[row*cols+col].refs.0 != 0 {
            let v = previous[row*cols+col].vectors.0, co = clampVector(VP9MV(row: (v.row/8)*8, col: (v.col/8)*8))
            let c = cost(3, co)
            if c < centerCost { center = co; centerCost = c }
        }
        let wide = measure(center) > n*n*6
        for step in wide ? [64, 32, 16, 8] : [8] {
            var moved = true, rounds = 0
            while moved && rounds < (step == 8 ? 16 : 4) {
                moved = false; rounds += 1
                let origin = center
                for (dr, dc) in [(-step,0),(step,0),(0,-step),(0,step)] {
                    let mv = clampVector(VP9MV(row: origin.row+dr, col: origin.col+dc))
                    let c = cost(3, mv)
                    if c < centerCost { center = mv; centerCost = c; moved = true }
                }
            }
        }
        // Fractional refinement, unless the whole-sample match is already within half a level
        // a sample; quarter samples only around an improved half sample, or a poor match.
        if measure(center)*2 > n*n {
            var improved = false
            for step in [4, 2] where step == 4 || improved || measure(center) > n*n*4 {
                let origin = center
                for (dr, dc) in [(-step,0),(step,0),(0,-step),(0,step)] {
                    let mv = clampVector(VP9MV(row: origin.row+dr, col: origin.col+dc))
                    let c = cost(3, mv)
                    if c < centerCost { center = mv; centerCost = c; improved = true }
                }
            }
        }
        // The finalists by their exact SAD (ranking used bilinear estimates at fractions).
        var final = (mode: 2, mv: VP9MV(), cost: measure(VP9MV())*256 + lambda*modeBits[2])
        for (mode, mv) in [(0, nearest), (1, near), (3, center)] {
            var bits = modeBits[mode]
            if mode == 3 {
                // A searched vector equal to a candidate is coded as that candidate.
                if mv == nearest || mv == near { continue }
                bits += EncoderBoolean.motionVectorBits(row: mv.row-nearest.row, col: mv.col-nearest.col)
            }
            let c = exactSad(mv, x, y, n)*256 + lambda*bits
            if c < final.cost { final = (mode, mv, c) }
        }
        _ = best
        return (final.mode, final.mv)
    }

    /// 8x the orthonormal 2-D DCT-II of a 8x8 residual: VP9's coefficient scale (libvpx's
    /// forward transforms; any accurate one serves, as reconstruction uses the decoder's inverse).
    private static func forwardDCT8(_ r: borrowing Span<Float>, _ out: inout MutableSpan<Float>) {
        let basis = dct8Basis, transposed = dct8Transposed
        var rows = InlineArray<8, SIMD8<Float>>(repeating: SIMD8<Float>())
        for i in 0..<8 { rows[i] = SIMD8<Float>(r[i*8+0], r[i*8+1], r[i*8+2], r[i*8+3], r[i*8+4], r[i*8+5], r[i*8+6], r[i*8+7]) }
        // Columns: T_k = sum over i of C[k][i] * row i.
        var columns = InlineArray<8, SIMD8<Float>>(repeating: SIMD8<Float>())
        for k in 0..<8 {
            var sum = SIMD8<Float>()
            for i in 0..<8 { sum += SIMD8<Float>(repeating: basis[k*8+i]) * rows[i] }
            columns[k] = sum
        }
        // Rows: X_k = sum over j of T[k][j] * (row j of C transposed).
        for k in 0..<8 {
            var sum = SIMD8<Float>()
            let row = columns[k]
            for j in 0..<8 { sum += SIMD8<Float>(repeating: row[j]) * transposed[j] }
            for l in 0..<8 { out[k*8+l] = sum[l] }
        }
    }
    /// sqrt(8) times the orthonormal DCT-II basis, C[k][i] at k*8+i (two passes: 8x), and its transpose by rows.
    private static let dct8Basis: [Float] = (0..<64).map { index in
        let k = index / 8, i = index % 8
        let scale = (8.0 * 2.0 / 8.0).squareRoot() * (k == 0 ? (0.5).squareRoot() : 1)
        return Float(scale * cosPi64(4*(2*i+1)*k))
    }
    private static let dct8Transposed: [SIMD8<Float>] = (0..<8).map { j in
        var row = SIMD8<Float>()
        for l in 0..<8 { row[l] = dct8Basis[l*8+j] }
        return row
    }

    /// 8x the orthonormal 2-D DCT-II of a 16x16 residual: VP9's coefficient scale (libvpx's
    /// forward transforms; any accurate one serves, as reconstruction uses the decoder's inverse).
    private static func forwardDCT16(_ r: borrowing Span<Float>, _ out: inout MutableSpan<Float>) {
        let basis = dct16Basis, transposed = dct16Transposed
        var rows = InlineArray<16, SIMD16<Float>>(repeating: SIMD16<Float>())
        for i in 0..<16 { rows[i] = SIMD16<Float>(r[i*16+0], r[i*16+1], r[i*16+2], r[i*16+3], r[i*16+4], r[i*16+5], r[i*16+6], r[i*16+7], r[i*16+8], r[i*16+9], r[i*16+10], r[i*16+11], r[i*16+12], r[i*16+13], r[i*16+14], r[i*16+15]) }
        // Columns: T_k = sum over i of C[k][i] * row i.
        var columns = InlineArray<16, SIMD16<Float>>(repeating: SIMD16<Float>())
        for k in 0..<16 {
            var sum = SIMD16<Float>()
            for i in 0..<16 { sum += SIMD16<Float>(repeating: basis[k*16+i]) * rows[i] }
            columns[k] = sum
        }
        // Rows: X_k = sum over j of T[k][j] * (row j of C transposed).
        for k in 0..<16 {
            var sum = SIMD16<Float>()
            let row = columns[k]
            for j in 0..<16 { sum += SIMD16<Float>(repeating: row[j]) * transposed[j] }
            for l in 0..<16 { out[k*16+l] = sum[l] }
        }
    }
    /// sqrt(8) times the orthonormal DCT-II basis, C[k][i] at k*16+i (two passes: 8x), and its transpose by rows.
    private static let dct16Basis: [Float] = (0..<256).map { index in
        let k = index / 16, i = index % 16
        let scale = (8.0 * 2.0 / 16.0).squareRoot() * (k == 0 ? (0.5).squareRoot() : 1)
        return Float(scale * cosPi64(2*(2*i+1)*k))
    }
    private static let dct16Transposed: [SIMD16<Float>] = (0..<16).map { j in
        var row = SIMD16<Float>()
        for l in 0..<16 { row[l] = dct16Basis[l*16+j] }
        return row
    }

    private static func forward(_ values: inout Coefficients, lossless: Bool) {
        if !lossless {
            for i in 0..<16 { values[i] *= 16 }
            if values[0] != 0 { values[0] += 1 }
        }
        var out = values
        for _ in 0..<2 {
            for i in 0..<4 {
                var a = values[i], b = values[4+i], c = values[8+i], d = values[12+i]
                if lossless {
                    a += b
                    d -= c
                    let e = (a-d) >> 1
                    b = e-b
                    c = e-c
                    out[4*i] = a-c
                    out[4*i+1] = c
                    out[4*i+2] = d+b
                    out[4*i+3] = b
                } else {
                    let p = a+d, t = b+c, r = b-c, s = a-d
                    out[4*i] = ((p+t)*11585+8192) >> 14
                    out[4*i+2] = ((p-t)*11585+8192) >> 14
                    out[4*i+1] = (r*6270+s*15137+8192) >> 14
                    out[4*i+3] = (s*6270-r*15137+8192) >> 14
                }
            }
            swap(&out,&values)
        }
        for i in 0..<16 { values[i] = lossless ? values[i]*4 : (values[i]+1) >> 2 }
    }
}

private struct EncoderBoolean {
    init() { put(false) }
    private var bytes: [UInt8] = []
    private var low: UInt32 = 0
    private var range = 255
    private var count = -24

    mutating func put(_ bit: Bool, _ probability: Int = 128) {
        let split = 1 + (((range - 1) * probability) >> 8)
        if bit { low &+= UInt32(split); range -= split } else { range = split }
        var shift = UInt8(range).leadingZeroBitCount
        range <<= shift
        count += shift
        if count >= 0 {
            let offset = shift - count
            if low & (UInt32(1) << (32 - offset)) != 0 {
                var i = bytes.count
                while i > 0, bytes[i-1] == 255 { i -= 1; bytes[i] = 0 }
                if i > 0 { bytes[i-1] += 1 } else { bytes.insert(1, at: 0) }
            }
            bytes.append(UInt8(truncatingIfNeeded: low >> (24 - offset)))
            low = (low << offset) & 0xff_ffff
            shift = count
            count -= 8
        }
        low <<= shift
    }

    mutating func literal(_ value: Int, bits: Int) {
        for i in (0..<bits).reversed() { put(value & (1 << i) != 0) }
    }

    mutating func finish() -> [UInt8] {
        for _ in 0..<32 { put(false) }
        if let final = bytes.last, final & 224 == 192 { bytes.append(0) }
        return bytes
    }

    private static let bands = [0,1,1,2,2,2,3,3,3,3,4,4,4,5,5,5]
    private static let bandsLarge = [0,1,1,2,2,2,3,3,3,3,4,4,4,4,4,4,4,4,4,4,4]
    private static let thresholds = [5,7,11,19,35,67]
    private static let extra = [[159],[165,145],[173,148,140],[176,155,140,135],[180,157,141,134,130],
                                 [254,254,254,252,249,243,230,196,177,153,140,133,130,129]]
    /// Token classes by coefficient index while a block is written (zero between blocks).
    private var energy = [Int](repeating: 0, count: 256)

    /// The bits (1/256) residual would write for these levels: the same walk, costed.
    mutating func residualBits(_ levels: [Int], start: Int, tx: Int, end: Int, chroma: Bool, inter: Bool, context: Int) -> Int {
        let scan = tx == 0 ? VP9Table.defaultScan4x4 : tx == 1 ? VP9Table.defaultScan8x8 : VP9Table.defaultScan16x16
        let adj = tx == 0 ? VP9Table.defaultScanNb4x4 : tx == 1 ? VP9Table.defaultScanNb8x8 : VP9Table.defaultScanNb16x16
        let bands = tx == 0 ? Self.bands : Self.bandsLarge, probs = VP9Table.coefProbs, tree = VP9Table.pareto8Full
        let base = ((tx*2 + (chroma ? 1 : 0))*2 + (inter ? 1 : 0))*108, limit = scan.count
        var ctx = context, afterZero = false, bits = 0
        for i in 0..<limit {
            let p = base + (i < bands.count ? bands[i] : 5)*18 + 3*ctx
            if !afterZero { bits += Self.cost(i < end, probs[p]) }
            if i == end { break }
            let index = scan[i], value = abs(levels[start+index])
            afterZero = value == 0
            bits += Self.cost(!afterZero, probs[p+1])
            if value != 0 {
                let prob = probs[p+2], t = (prob-1)*8
                bits += Self.cost(value > 1, prob) + 256
                var token = 1
                if value > 1 {
                    bits += Self.cost(value >= 5, tree[t])
                    if value < 5 {
                        bits += Self.cost(value > 2, tree[t+1])
                        if value > 2 { bits += Self.cost(value == 4, tree[t+2]) }
                        token = min(3, value)
                    } else {
                        let category = Self.thresholds.lastIndex(where: { value >= $0 }) ?? 0
                        bits += Self.cost(category >= 2, tree[t+3])
                        if category < 2 { bits += Self.cost(category == 1, tree[t+4]) }
                        else { bits += Self.cost(category >= 4, tree[t+5]) + Self.cost(category % 2 != 0, tree[t+(category < 4 ? 6 : 7)]) }
                        bits += Self.extra[category].count*256
                        token = category < 2 ? 4 : 5
                    }
                }
                energy[index] = token
            }
            if i+1 < limit { ctx = (1+energy[adj[2*i+2]]+energy[adj[2*i+3]]) >> 1 }
        }
        for k in 0..<min(end, limit) { energy[scan[k]] = 0 }
        return bits
    }

    /// A transform block's tokens (VP9Context.tokens read them): levels[start...] in raster
    /// order, the default scan of transform size tx, `end` scan positions.
    mutating func residual(_ levels: [Int], start: Int, tx: Int, end: Int, chroma: Bool, inter: Bool, context: Int) {
        let scan = tx == 0 ? VP9Table.defaultScan4x4 : tx == 1 ? VP9Table.defaultScan8x8 : VP9Table.defaultScan16x16
        let adj = tx == 0 ? VP9Table.defaultScanNb4x4 : tx == 1 ? VP9Table.defaultScanNb8x8 : VP9Table.defaultScanNb16x16
        let bands = tx == 0 ? Self.bands : Self.bandsLarge
        let base = ((tx*2 + (chroma ? 1 : 0))*2 + (inter ? 1 : 0))*108, limit = scan.count
        var ctx = context, afterZero = false
        for i in 0..<limit {
            let p = base + (i < bands.count ? bands[i] : 5)*18 + 3*ctx
            if !afterZero { put(i < end,VP9Table.coefProbs[p]) }
            if i == end { break }
            let index = scan[i], level = levels[start+index], value = abs(level)
            afterZero = value == 0
            put(!afterZero,VP9Table.coefProbs[p+1])
            if value != 0 {
                let prob = VP9Table.coefProbs[p+2]
                put(value > 1,prob)
                var token = 1
                if value > 1 {
                    let t = (prob-1)*8, probs = VP9Table.pareto8Full
                    put(value >= 5,probs[t])
                    if value < 5 {
                        put(value > 2,probs[t+1])
                        if value > 2 { put(value == 4,probs[t+2]) }
                        token = min(3,value)
                    } else {
                        let category = Self.thresholds.lastIndex(where: { value >= $0 }) ?? 0
                        put(category >= 2,probs[t+3])
                        if category < 2 { put(category == 1,probs[t+4]) }
                        else {
                            put(category >= 4,probs[t+5])
                            put(category % 2 != 0,probs[t+(category < 4 ? 6 : 7)])
                        }
                        let bits = Self.extra[category], offset = value-Self.thresholds[category]
                        for (i,p) in bits.enumerated() { put(offset & (1 << (bits.count-i-1)) != 0,p) }
                        token = category < 2 ? 4 : 5
                    }
                }
                put(level < 0)
                energy[index] = token
            }
            if i+1 < limit { ctx = (1+energy[adj[2*i+2]]+energy[adj[2*i+3]]) >> 1 }
        }
        for k in 0..<min(end, limit) { energy[scan[k]] = 0 }
    }

    // MARK: Inter modes and motion vectors, as VP9Tile.interModes and differential read them

    static func cost(_ bit: Bool, _ probability: Int) -> Int { EncoderTile.bitCost[bit ? 256-probability : probability] }

    /// ZEROMV 0; NEARESTMV 1,0; NEARMV 1,1,0; NEWMV 1,1,1 (modes numbered as VP9Block.motionMode).
    mutating func interMode(_ mode: Int, context: Int) {
        let probs = VP9Table.interModeProbs, p = context*3
        put(mode != 2, probs[p])
        if mode != 2 {
            put(mode != 0, probs[p+1])
            if mode != 0 { put(mode == 3, probs[p+2]) }
        }
    }

    /// The bits (1/256) of each mode, indexed by motionMode.
    static func interModeBits(context: Int) -> InlineArray<4, Int> {
        let probs = VP9Table.interModeProbs, p = context*3
        let notZero = cost(true, probs[p]), rest = notZero + cost(true, probs[p+1])
        return [notZero + cost(false, probs[p+1]), rest + cost(false, probs[p+2]), cost(false, probs[p]), rest + cost(true, probs[p+2])]
    }

    private static let fourValues = [0,2,-1,4,-2,-3]
    private static let classTree = [0,2,-1,4,6,8,-2,-3,10,12,-4,-5,-6,14,16,18,-7,-8,-9,-10]
    /// For each value of a tree, its path from the root: (probability index, bit) per node.
    private static func paths(_ shape: [Int], count: Int) -> [[(Int, Bool)]] {
        var result = [[(Int, Bool)]](repeating: [], count: count)
        func walk(_ node: Int, _ path: [(Int, Bool)]) {
            for bit in 0..<2 {
                let next = shape[node+bit], step = path + [(node/2, bit == 1)]
                if next <= 0 { result[-next] = step } else { walk(next, step) }
            }
        }
        walk(0, [])
        return result
    }
    private static let fourPaths = paths(fourValues, count: 4), classPaths = paths(classTree, count: 11)

    /// The symbols of a vector difference in eighth samples (both components even: no high
    /// precision, whose bit the decoder then takes as one): joint, then row, then column.
    static func vectorSymbols(row: Int, col: Int, _ emit: (Bool, Int) -> Void) {
        let probs = VP9Prob.initial
        for (node, bit) in fourPaths[(row != 0 ? 2 : 0) | (col != 0 ? 1 : 0)] { emit(bit, probs[VP9Prob.joint+node]) }
        for (axis, value) in [(0, row), (1, col)] where value != 0 {
            emit(value < 0, probs[VP9Prob.sign+axis])
            let offset = abs(value) - 1
            let cls = offset < 16 ? 0 : Int.bitWidth - (offset >> 3).leadingZeroBitCount - 1
            for (node, bit) in classPaths[cls] { emit(bit, probs[VP9Prob.mvClass+10*axis+node]) }
            let rest = offset - (cls == 0 ? 0 : 8 << cls), integer = rest >> 3, fraction = (rest >> 1) & 3
            if cls == 0 { emit(integer == 1, probs[VP9Prob.class0+axis]) }
            else { for bit in 0..<cls { emit((integer >> bit) & 1 == 1, probs[VP9Prob.mvBits+10*axis+bit]) } }
            let base = cls == 0 ? VP9Prob.class0Fr+6*axis+3*integer : VP9Prob.mvFr+3*axis
            for (node, bit) in fourPaths[fraction] { emit(bit, probs[base+node]) }
        }
    }

    mutating func motionVector(row: Int, col: Int) {
        var symbols: [(Bool, Int)] = []
        Self.vectorSymbols(row: row, col: col) { symbols.append(($0, $1)) }
        for (bit, probability) in symbols { put(bit, probability) }
    }

    /// The bits of a vector difference: the joint plus each component's (looked up for the
    /// differences a search produces, counted symbol by symbol beyond).
    static func motionVectorBits(row: Int, col: Int) -> Int {
        let r = row + componentRange, c = col + componentRange
        guard (0...2*componentRange).contains(r), (0...2*componentRange).contains(c) else {
            var bits = 0
            vectorSymbols(row: row, col: col) { bits += cost($0, $1) }
            return bits
        }
        return jointBits[(row != 0 ? 2 : 0) | (col != 0 ? 1 : 0)] + rowBits[r] + columnBits[c]
    }
    private static let componentRange = 4096
    private static let jointBits = (0..<4).map { joint in
        fourPaths[joint].reduce(0) { $0 + cost($1.1, VP9Prob.initial[VP9Prob.joint+$1.0]) }
    }
    private static let rowBits = componentBits(axis: 0), columnBits = componentBits(axis: 1)
    private static func componentBits(axis: Int) -> [Int] {
        (-componentRange...componentRange).map { value in
            guard value != 0 else { return 0 }
            var bits = 0
            vectorSymbols(row: axis == 0 ? value : 0, col: axis == 0 ? 0 : value) { bits += cost($0, $1) }
            return bits - jointBits[axis == 0 ? 2 : 1]
        }
    }
}

/// Dependencies are relative to source pictures. A lower spatial reference always
/// belongs to this same picture; temporal distances count whole pictures on RTP.
public struct VP9EncodedLayer: Sendable {
    public let bytes: [UInt8]
    public let width, height, spatialID, temporalID: Int
    public let temporalReferenceDiff: Int?
    public let dependsOnLower, switchingUp, refresh: Bool
}

public struct VP9ScalableEncoder: Sendable {
    private let spatialCount, temporalCount: Int
    private let independent, keyOnly, shift, twoThirds: Bool
    private var slots = [VP9VideoEncoder](repeating:.init(),count:8)
    private var pictureNumbers = [Int](repeating:0,count:8)
    private var temporalIDs = [Int](repeating:0,count:8)
    private var pictureNumber = 0
    private var lastWidth = 0, lastHeight = 0

    public init?(mode: String) {
        let letters = Array(mode.utf8)
        guard (4...14).contains(letters.count), letters[0] == 76 || letters[0] == 83,
              (49...51).contains(letters[1]), letters[2] == 84, (49...51).contains(letters[3]) else { return nil }
        spatialCount = Int(letters[1]-48)
        temporalCount = Int(letters[3]-48)
        independent = letters[0] == 83
        let suffix = String(decoding:letters.dropFirst(4),as:UTF8.self)
        keyOnly = suffix == "_KEY" || suffix == "_KEY_SHIFT"
        shift = suffix == "_KEY_SHIFT"
        twoThirds = suffix == "h"
        guard suffix.isEmpty || keyOnly || twoThirds,
              !independent || (spatialCount >= 2 && !keyOnly),
              spatialCount > 1 || suffix.isEmpty,
              !shift || (spatialCount == 2 && temporalCount == 2) else { return nil }
    }

    public mutating func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                quantizer: Int = 72, keyframe: Bool = false) -> [VP9EncodedLayer]? {
        guard (1...4096).contains(width), (1...4096).contains(height), width*height <= 3840*2160,
              y.count == width*height, u.count == ((width+1)/2)*((height+1)/2), v.count == u.count,
              (0...255).contains(quantizer) else { return nil }
        let refresh = keyframe || width != lastWidth || height != lastHeight || pictureNumber >= 120
        if refresh { pictureNumber = 0 }
        let clock = pictureNumber
        var sizes = [(width,height)]
        for _ in 1..<spatialCount {
            let prior = sizes[sizes.count-1]
            if twoThirds { sizes.append((max(1,prior.0*2/3),max(1,prior.1*2/3))) }
            else { sizes.append((max(1,prior.0/2),max(1,prior.1/2))) }
        }
        var result: [VP9EncodedLayer] = []
        var lowerSlot = 0
        for (sid,(w,h)) in sizes.reversed().enumerated() {
            let phase = shift && sid == 1 && !refresh ? clock+1 : clock
            let tid = refresh || temporalCount == 1 ? 0 : temporalCount == 2 ? phase % 2 : [0,2,1,2][phase % 4]
            let spatial = sid > 0 && !independent && (refresh || !keyOnly)
            let temporalSlot = temporalCount == 3 && tid == 2 && clock % 4 == 3 ? sid+3 : sid
            let read = spatial ? lowerSlot : temporalSlot
            let write = tid == 0 ? sid : (temporalCount == 3 && tid == 1 ? sid+3 : 6+sid%2)
            let diff = spatial || refresh ? nil : clock-pictureNumbers[read]
            let switches = tid > 0 && (spatial || temporalIDs[read] < tid)
            var encoder = slots[read]
            let bytes = encoder.picture(width:w,height:h,
                y:Self.scale(y,width,height,w,h),u:Self.scale(u,(width+1)/2,(height+1)/2,(w+1)/2,(h+1)/2),
                v:Self.scale(v,(width+1)/2,(height+1)/2,(w+1)/2,(h+1)/2),q:quantizer,
                key:refresh && sid == 0, independent:refresh && independent && sid > 0,
                readSlot:read,writeSlot:write)
            slots[write] = encoder
            pictureNumbers[write] = clock
            temporalIDs[write] = tid
            lowerSlot = write
            result.append(.init(bytes:bytes,width:w,height:h,spatialID:sid,temporalID:tid,temporalReferenceDiff:diff,
                                dependsOnLower:spatial,switchingUp:switches,refresh:refresh))
        }
        lastWidth = width
        lastHeight = height
        pictureNumber += 1
        return result
    }

    private static func scale(_ input: [UInt8], _ width: Int, _ height: Int, _ w: Int, _ h: Int) -> [UInt8] {
        if w == width && h == height { return input }
        var output = [UInt8](repeating:0,count:w*h)
        for row in 0..<h {
            let src = (row*height/h)*width
            for col in 0..<w { output[row*w+col] = input[src+col*width/w] }
        }
        return output
    }
}

/// The OR of the XORs of count samples from i in a and b: zero when they are the same. Vector
/// operations only (SIMD equality compiles to a loop over the lanes).
@inline(__always)
private func sampleDifference(_ a: borrowing Span<UInt8>, _ b: borrowing Span<UInt8>, _ i: Int, _ count: Int) -> SIMD8<UInt8> {
    var difference = SIMD8<UInt8>()
    var k = 0
    while k &+ 8 <= count {
        difference |= eightSamples(a, i &+ k) ^ eightSamples(b, i &+ k)
        k &+= 8
    }
    while k < count {
        difference[0] |= a[i &+ k] ^ b[i &+ k]
        k &+= 1
    }
    return difference
}

/// Whether every lane is zero (a widened sum cannot wrap to zero).
@inline(__always)
private func isZero(_ v: SIMD8<UInt8>) -> Bool { SIMD8<UInt16>(truncatingIfNeeded: v).wrappedSum() == 0 }

@inline(__always)
private func eightSamples(_ s: borrowing Span<UInt8>, _ i: Int) -> SIMD8<UInt8> {
    let w = s.extracting(i..<(i &+ 8))
    return SIMD8(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7])
}

/// round(|value| / step) with the sign kept, by a reciprocal and without branches: with
/// m = ceil(2^32 / step), floor(n*m / 2^32) is floor(n / step) for every n below 2^32 / step
/// (steps are below 2^11 and coefficients below 2^15 here).
struct QuantizerStep {
    let step: Int, half: Int, reciprocal: Int
    init(_ step: Int) { self.step = step; half = step / 2; reciprocal = ((1 << 32) + step - 1) / step }

    @inline(__always)
    func quantize(_ value: Int) -> Int {
        let sign = value >> 63
        let level = ((((value ^ sign) &- sign) &+ half) &* reciprocal) >> 32
        return (level ^ sign) &- sign
    }
}

/// cos(m * pi / 64) for any integer m, in Double from a series after reducing the angle to
/// [0, pi/2] (the codec modules have no libm; every DCT angle here is such a multiple).
private func cosPi64(_ m: Int) -> Double {
    var a = ((m % 128) + 128) % 128, sign = 1.0
    if a > 64 { a = 128 - a }
    if a > 32 { a = 64 - a; sign = -1 }
    let x = Double(a) * Double.pi / 64
    var term = 1.0, sum = 1.0
    for n in 1...12 { term *= -x*x / Double((2*n-1)*(2*n)); sum += term }
    return sign*sum
}

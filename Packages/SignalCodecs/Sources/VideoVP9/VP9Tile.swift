/// Per-MI neighbour state (8×8), including the four luma sub-blocks in decode order.
/// A motion vector in eighth samples. Decoded vectors are held to ±16383 (differential), and
/// candidates are clamped toward zero, so 16 bits hold every value.
struct VP9MV: Hashable {
    private var r: Int16 = 0, c: Int16 = 0
    init(row: Int = 0, col: Int = 0) { r = Int16(truncatingIfNeeded: row); c = Int16(truncatingIfNeeded: col) }
    var row: Int { get { Int(r) } set { r = Int16(truncatingIfNeeded: newValue) } }
    var col: Int { get { Int(c) } set { c = Int16(truncatingIfNeeded: newValue) } }
}
/// A sub-8x8 block's four vector pairs, inline so a block copies without reference counting.
struct VP9SubVectors {
    private var pairs = InlineArray<4, (VP9MV,VP9MV)>(repeating: (VP9MV(),VP9MV()))
    subscript(_ i: Int) -> (VP9MV,VP9MV) {
        get { pairs[i] }
        set { pairs[i] = newValue }
    }
}
/// Per-MI neighbour state (8×8), including the four luma sub-blocks in decode order. Every
/// field is small (sizes ≤ 64, modes ≤ 9, levels ≤ 63, references ≤ 3, positions < 2^16),
/// so it is stored packed (neighbour reads copy blocks) behind Int accessors.
struct VP9Block {
    private var w: UInt8, h: UInt8, t: UInt8 = 0, s: UInt8 = 0, l: UInt8 = 0
    private var x: Int32 = 0, y: Int32 = 0
    var skip = false, predictedSegment = false
    private var m0: UInt8 = 0, m1: UInt8 = 0, m2: UInt8 = 0, m3: UInt8 = 0, uv: UInt8 = 0
    private var r0: Int8 = 0, r1: Int8 = 0, mm: UInt8 = 0, f: UInt8 = 4
    var vectors = (VP9MV(),VP9MV())
    var subVectors: VP9SubVectors?

    init(width: Int = 8, height: Int = 8) { w = UInt8(truncatingIfNeeded: width); h = UInt8(truncatingIfNeeded: height) }
    var width: Int { get { Int(w) } set { w = UInt8(truncatingIfNeeded: newValue) } }
    var height: Int { get { Int(h) } set { h = UInt8(truncatingIfNeeded: newValue) } }
    var tx: Int { get { Int(t) } set { t = UInt8(truncatingIfNeeded: newValue) } }
    var segment: Int { get { Int(s) } set { s = UInt8(truncatingIfNeeded: newValue) } }
    var level: Int { get { Int(l) } set { l = UInt8(truncatingIfNeeded: newValue) } }
    var originX: Int { get { Int(x) } set { x = Int32(truncatingIfNeeded: newValue) } }
    var originY: Int { get { Int(y) } set { y = Int32(truncatingIfNeeded: newValue) } }
    var yModes: (Int,Int,Int,Int) {
        get { (Int(m0),Int(m1),Int(m2),Int(m3)) }
        set { (m0,m1,m2,m3) = (UInt8(truncatingIfNeeded: newValue.0),UInt8(truncatingIfNeeded: newValue.1),
                               UInt8(truncatingIfNeeded: newValue.2),UInt8(truncatingIfNeeded: newValue.3)) }
    }
    var uvMode: Int { get { Int(uv) } set { uv = UInt8(truncatingIfNeeded: newValue) } }
    var refs: (Int,Int) {
        get { (Int(r0),Int(r1)) }
        set { (r0,r1) = (Int8(truncatingIfNeeded: newValue.0),Int8(truncatingIfNeeded: newValue.1)) }
    }
    var motionMode: Int { get { Int(mm) } set { mm = UInt8(truncatingIfNeeded: newValue) } }
    var filter: Int { get { Int(f) } set { f = UInt8(truncatingIfNeeded: newValue) } }
    func mode(_ x: Int, _ y: Int) -> Int {
        switch y*2+x { case 0: Int(m0); case 1: Int(m1); case 2: Int(m2); default: Int(m3) }
    }
}
/// A decoded frame: read-only once built, so tiles on other threads can predict from it.
final class VP9Picture: Sendable {
    let cols, rows: Int
    let planes: [VP9Plane]
    let blocks: [VP9Block]
    init(cols: Int, rows: Int, planes: [VP9Plane], blocks: [VP9Block]) {
        self.cols = cols; self.rows = rows; self.planes = planes; self.blocks = blocks
    }
    /// A frame's three planes, or the strips of them under MI columns `columns`.
    static func planes(width: Int, height: Int, columns: Range<Int>? = nil) -> [VP9Plane] {
        let cols = (width+7)/8, chromaWidth = (width+1)/2, chromaHeight = (height+1)/2
        func strip(_ planeWidth: Int, _ shift: Int, _ chroma: Bool) -> VP9Plane {
            let stride = (planeWidth+63)/64*64
            guard let columns else { return VP9Plane(width: planeWidth, height: planeHeight(chroma), chroma: chroma) }
            let lower = (columns.lowerBound*8) >> shift
            // The last column also owns the padding out to the stride, which transform blocks at
            // the edge write and the loop filter reads; an empty column owns nothing.
            let upper = columns.upperBound >= cols && !columns.isEmpty ? stride : (columns.upperBound*8) >> shift
            return VP9Plane(width: planeWidth, height: planeHeight(chroma), chroma: chroma, columns: lower..<max(lower,upper))
        }
        func planeHeight(_ chroma: Bool) -> Int { chroma ? chromaHeight : height }
        return [strip(width,0,false), strip(chromaWidth,1,true), strip(chromaWidth,1,true)]
    }
}

/// One tile column, decoded tile row by tile row: it owns the column's strips of the frame's
/// planes, its MIs (right-left per row), its above contexts and its symbol counts, so
/// columns can decode independently (VP9 has no dependencies between tile columns).
struct VP9Tile {
    let h: VP9Header
    var context: VP9Context
    let references: [VP9Picture?], previous: VP9Picture?
    let usePreviousMVs: Bool
    /// The frame's size in MIs, and this column's MI columns.
    let cols, rows: Int
    let left, right: Int
    private(set) var top = 0, bottom = 0
    var coder: VP9Boolean
    var planes: [VP9Plane]
    var blocks: [VP9Block]
    var partAbove, partLeft: [Int]
    var nzAbove, nzLeft: [[Int]]
    let refDelta: [Int], modeDelta: [Int]
    /// Reused per transform block: all zero between blocks.
    var coefficients = [Int](repeating: 0, count: 1024), energy = [UInt8](repeating: 0, count: 1024)
    /// After decoding: the loop filter's edge codes for this column's 4x4 units of each plane
    /// (all unit rows, `filterWidths[p]` units per row), or empty when the frame has no filter.
    private(set) var filterCodes: [[Int32]] = [], filterWidths: [Int] = []

    init(h: VP9Header, context: VP9Context, references: [VP9Picture?], previous: VP9Picture?, usePreviousMVs: Bool,
         columns: Range<Int>, refDelta: [Int], modeDelta: [Int], firstTile data: ArraySlice<UInt8>, rows tileRows: Range<Int>) throws {
        self.h = h; self.context = context.freshCounts; self.references = references; self.previous = previous
        self.usePreviousMVs = usePreviousMVs
        cols = (h.width+7)/8; rows = (h.height+7)/8
        (left,right) = (columns.lowerBound,columns.upperBound)
        self.refDelta = refDelta; self.modeDelta = modeDelta
        coder = try .init(data)
        (top,bottom) = (tileRows.lowerBound,tileRows.upperBound)
        planes = VP9Picture.planes(width: h.width, height: h.height, columns: cols == columns.count ? nil : columns)
        blocks = [VP9Block](repeating: .init(), count: columns.count*rows)
        partAbove = .init(repeating:0,count:cols+8); partLeft = .init(repeating:0,count:rows+8)
        nzAbove = .init(repeating: .init(repeating:0,count:cols*2+16),count:3)
        nzLeft = .init(repeating: .init(repeating:0,count:rows*2+16),count:3)
    }
    /// The next tile row of this column. Left contexts are indexed by frame row, so the new
    /// rows' entries are still zero; above contexts carry on from the tile above.
    mutating func next(_ data: ArraySlice<UInt8>, rows tileRows: Range<Int>) throws {
        coder = try .init(data)
        (top,bottom) = (tileRows.lowerBound,tileRows.upperBound)
    }
    /// Work out filterCodes from this column's blocks (they depend on nothing else), so the
    /// columns do it in parallel rather than the frame's filter.
    mutating func decideFilterEdges() {
        let span = right-left
        filterCodes = []; filterWidths = []
        for index in 0..<3 {
            let chroma = index != 0, shift = chroma ? 1 : 0
            let (unitRows, unitCols) = VP9Plane.units(width: chroma ? (h.width+1)/2 : h.width,
                                                      height: chroma ? (h.height+1)/2 : h.height, chroma: chroma)
            let first = chroma ? left : left*2
            let last = max(first, right == cols ? unitCols : (chroma ? right : right*2))
            var codes = [Int32](repeating: 0, count: unitRows*(last-first))
            var out = codes.mutableSpan
            for row4 in 0..<unitRows {
                for col4 in first..<last {
                    let x = (col4*4) << shift, y = (row4*4) << shift
                    let cellX = min(cols-1, chroma ? col4 & ~1 : x/8), cellY = min(rows-1, chroma ? row4 & ~1 : y/8)
                    let b = blocks[cellY*span + cellX-left]
                    let size = min(max(8,b.width),max(8,b.height)).trailingZeroBitCount
                    out[row4*(last-first) + col4-first] = VP9Plane.edgeCode(
                        level: b.level, tx: min(b.tx,size-shift-2), skip: b.skip && b.refs.0 != 0,
                        left: x == b.originX, top: y == b.originY, row: row4, col: col4, rows: unitRows, cols: unitCols, chroma: chroma)
                }
            }
            filterCodes.append(codes); filterWidths.append(last-first)
        }
    }
    func neighbour(_ col: Int, _ row: Int) -> VP9Block? {
        guard col >= left, col < right, row >= 0, row < rows else { return nil }
        return blocks[row*(right-left)+col-left]
    }
    mutating func decode() throws {
        for row in stride(from:top,to:bottom,by:8) {
            for col in stride(from:left,to:right,by:8) { try partition(col,row,level:3) }
        }
        guard !coder.exhausted else { throw VP9DecodeError.malformed }
    }
    mutating func partition(_ col: Int, _ row: Int, level: Int) throws {
        guard col < right, row < bottom else { return }
        let size = 1 << level, half = size/2
        let hasRows = row+half < rows, hasCols = col+half < cols
        let at = 3*(level*4 + ((partAbove[col] >> level) & 1) + 2*((partLeft[row] >> level) & 1))
        func read(_ i: Int) -> Int {
            h.intra ? coder.bit(VP9Table.kfPartitionProbs[at+i]) : context.read(&coder,VP9Prob.partition+at+i)
        }
        let type: Int
        if hasRows && hasCols { type = read(0) == 0 ? 0 : (read(1) == 0 ? 1 : 2+read(2)) }
        else {
            // At the picture edge one bit is read, or none (a forced split), but libvpx counts
            // the whole resulting partition. Counting only the bit read desynchronised backward
            // adaptation from the encoder's (frame_parallel_decoding_mode 0, WebRTC's default).
            func edge(_ i: Int) -> Int {
                h.intra ? coder.bit(VP9Table.kfPartitionProbs[at+i]) : context.peek(&coder,VP9Prob.partition+at+i)
            }
            if hasCols { type = edge(1) == 0 ? 1 : 3 }
            else if hasRows { type = edge(2) == 0 ? 2 : 3 }
            else { type = 3 }
            if !h.intra { context.countPartition(VP9Prob.partition+at, type) }
        }
        let width = type == 2 || type == 3 ? size*4 : size*8
        let height = type == 1 || type == 3 ? size*4 : size*8
        if level == 0 || type == 0 { try block(col,row,width:width,height:height) }
        else if type == 3 {
            for y in 0..<2 { for x in 0..<2 { try partition(col+x*half,row+y*half,level:level-1) } }
            return
        } else {
            try block(col,row,width:width,height:height)
            if type == 1 && hasRows { try block(col,row+half,width:width,height:height) }
            if type == 2 && hasCols { try block(col+half,row,width:width,height:height) }
        }
        let wMask = (16 - width/4) & 15, hMask = (16 - height/4) & 15
        for i in 0..<size { partAbove[col+i] = wMask; partLeft[row+i] = hMask }
    }

    static let intraTree = [0,2,-9,4,-1,6,8,12,-2,10,-4,-5,-3,14,-8,16,-6,-7]
    static let segmentTree = [2,4,6,8,10,12,0,-1,-2,-3,-4,-5,-6,-7]
    static let noFeatures: [Int?] = [nil,nil,nil,nil]
    /// Intra mode to transform type (libvpx mode2txfm_map).
    static let modeTxType = [0,1,2,0,3,1,2,2,1,3]
    mutating func block(_ col: Int, _ row: Int, width: Int, height: Int) throws {
        let above = neighbour(col,row-1), leftBlock = neighbour(col-1,row)
        var b = VP9Block(width:width, height:height)
        b.originX = col*8; b.originY = row*8
        let subs = min(width,height) < 8
        if h.segmented {
            var predicted = 7
            let old = h.intra || h.resilient ? nil : previous.flatMap { p in p.cols == cols && p.rows == rows ? p : nil }
            if let old {
                for y in row..<min(rows,row+max(1,height/8)) {
                    for x in col..<min(cols,col+max(1,width/8)) { predicted = min(predicted,old.blocks[y*old.cols+x].segment) }
                }
            } else { predicted = 0 }
            if !h.intra, h.updateMap, h.temporalMap {
                let at = (above?.predictedSegment == true ? 1 : 0)+(leftBlock?.predictedSegment == true ? 1 : 0)
                b.predictedSegment = coder.bit(h.segmentation.prediction[at]) != 0
            }
            if h.updateMap && !b.predictedSegment {
                b.segment = coder.tree(Self.segmentTree,probs:h.segmentation.tree,at:0)
            } else if !h.intra { b.segment = predicted }
        }
        let features = h.segmented ? h.segmentation.features[b.segment] : Self.noFeatures
        let skipCtx = (above?.skip == true ? 1 : 0) + (leftBlock?.skip == true ? 1 : 0)
        b.skip = features[3] != nil || context.read(&coder,VP9Prob.skip+skipCtx) != 0
        let inter: Bool
        if h.intra { inter = false }
        else if let ref = features[2] { inter = ref != 0 }
        else {
            let a = above.map { $0.refs.0 == 0 }, l = leftBlock.map { $0.refs.0 == 0 }
            let ctx: Int
            if let a, let l { ctx = a && l ? 3 : (a || l ? 1 : 0) }
            else { ctx = (a ?? l) == true ? 2 : 0 }
            inter = context.read(&coder,VP9Prob.isInter+ctx) != 0
        }
        let maxTX = min(3,min(width,height).trailingZeroBitCount - 2)
        b.tx = min(maxTX,context.txMode)
        if maxTX > 0, context.txMode == 4, !b.skip || !inter {
            let a = above.map { $0.skip ? maxTX : $0.tx }, l = leftBlock.map { $0.skip ? maxTX : $0.tx }
            let ctx = (a ?? l ?? maxTX) + (l ?? a ?? maxTX) > maxTX ? 1 : 0
            let offset = (maxTX == 1 ? VP9Prob.tx8 : maxTX == 2 ? VP9Prob.tx16 : VP9Prob.tx32)+ctx*maxTX
            b.tx = 0
            while b.tx < maxTX, context.read(&coder,offset+b.tx) != 0 { b.tx += 1 }
        }
        if inter {
            try interModes(col:col,row:row,block:&b,forcedRef:features[2],forcedSkip:features[3] != nil)
        } else {
            var modes = InlineArray<4, Int>(repeating: 0)
            let stepX = width == 4 ? 1 : 2, stepY = height == 4 ? 1 : 2
            let group = min(3,min(width,height).trailingZeroBitCount-2)
            for y in stride(from:0,to:2,by:stepY) { for x in stride(from:0,to:2,by:stepX) {
                let mode: Int
                if h.intra {
                    let a = y > 0 ? modes[x] : (above?.mode(x,1) ?? 0)
                    let l = x > 0 ? modes[y*2] : (leftBlock?.mode(1,y) ?? 0)
                    mode = coder.tree(Self.intraTree,probs:VP9Table.KFYModeProbs,at:(a*10+l)*9)
                } else { mode = context.tree(&coder,Self.intraTree,VP9Prob.yMode+(subs ? 0 : group)*9) }
                for dy in 0..<stepY { for dx in 0..<stepX { modes[(y+dy)*2+x+dx] = mode } }
            } }
            b.yModes = (modes[0],modes[1],modes[2],modes[3])
            b.uvMode = h.intra ? coder.tree(Self.intraTree,probs:VP9Table.KFUVModeProbs,at:modes[3]*9) : context.tree(&coder,Self.intraTree,VP9Prob.uvMode+modes[3]*9)
        }
        let q = max(0,min(255,features[0].map { h.segmentation.absolute ? $0 : h.q+$0 } ?? h.q))
        var level = max(0,min(63,features[1].map { h.segmentation.absolute ? $0 : h.level+$0 } ?? h.level))
        if h.hasFilterDeltas {
            let scale = 1 << (h.level >> 5)
            level += refDelta[b.refs.0]*scale
            if inter { level += modeDelta[b.motionMode == 2 ? 0 : 1]*scale }
        }
        b.level = max(0,min(63,level))
        var hasTokens = false
        for p in 0..<3 {
            let shift = p == 0 ? 0 : 1
            let ox = (col*8) >> shift, oy = (row*8) >> shift
            let pw = max(8,width) >> shift, ph = max(8,height) >> shift
            let tx = min(b.tx,min(pw,ph).trailingZeroBitCount-2)
            let size = 4 << tx
            let dc = VP9Table.dcQLookup[max(0,min(255,q+(p == 0 ? h.yDC : h.uvDC)))]
            let ac = VP9Table.acQLookup[max(0,min(255,q+(p == 0 ? 0 : h.uvAC)))]
            if inter { try predictInter(col:col,row:row,plane:p,block:b) }
            for by in stride(from:0,to:ph,by:size) {
                let y = oy+by
                guard y < ((rows*8) >> shift) else { break }
                for bx in stride(from:0,to:pw,by:size) {
                    let x = ox+bx
                    guard x < ((cols*8) >> shift) else { break }
                    let mode = p == 0 ? b.mode(subs ? bx/4 : 1,subs ? by/4 : 1) : b.uvMode
                    if !inter {
                        planes[p].predictIntra(mode:mode,x:x,y:y,size:size,tileLeft:(left*8) >> shift,tileTop:0,haveRight:bx+size<pw)
                    }
                    let span = size/4, ix = x/4, iy = y/4
                    var nonzero = false
                    if !b.skip {
                        let above = nzAbove[p][ix..<(ix+span)].contains(1), left = nzLeft[p][iy..<(iy+span)].contains(1)
                        let type = !inter && p == 0 && tx < 3 && !h.lossless ? Self.modeTxType[mode] : 0
                        let end = context.residual(&coder,tx:tx,type:type,chroma:p != 0,inter:inter,
                            neighbours:(above ? 1 : 0)+(left ? 1 : 0),dc:dc,ac:ac,coefficients:&coefficients,energy:&energy)
                        nonzero = end > 0
                        if end == 1 && type == 0 && !h.lossless {
                            // Only DC: the 2-D DCT is one value everywhere (libvpx vpx_idct*_1_add).
                            planes[p].addConstant(VP9Transform.dcOnly(coefficients[0],size:size),x:x,y:y,size:size)
                            coefficients[0] = 0
                        } else if nonzero {
                            VP9Transform.apply(&coefficients,size:size,type:type,lossless:h.lossless)
                            planes[p].addResidual(&coefficients,x:x,y:y,size:size)
                        }
                    }
                    hasTokens = hasTokens || nonzero
                    for i in 0..<span {
                        nzAbove[p][ix+i] = nonzero && ix+i < ((cols*2) >> shift) ? 1 : 0
                        nzLeft[p][iy+i] = nonzero && iy+i < ((rows*2) >> shift) ? 1 : 0
                    }
                }
            }
        }
        // libvpx feeds a zero-EOB inter block of at least 8×8 back into both
        // the next block's skip probability and the loop filter.
        b.skip = b.skip || (inter && !subs && !hasTokens)
        let span = right-left
        for y in row..<min(bottom,row+max(1,height/8)) { for x in col..<min(right,col+max(1,width/8)) {
            blocks[y*span+x-left] = b
        } }
        if coder.exhausted { throw VP9DecodeError.malformed }
    }
}

extension VP9Tile {
    mutating func predictInter(col: Int, row: Int, plane: Int, block: VP9Block) throws {
        let subsampling = plane == 0 ? 0 : 1
        let width = max(8,block.width) >> subsampling, height = max(8,block.height) >> subsampling
        for i in 0..<(block.refs.1 == 0 ? 1 : 2) {
            let ref = i == 0 ? block.refs.0 : block.refs.1
            guard (1...3).contains(ref), let source = references[h.references[ref-1]] else { throw VP9DecodeError.missingReference }
            let refLuma = source.planes[0]
            guard refLuma.width <= h.width*2, refLuma.height <= h.height*2,
                  h.width <= refLuma.width*16, h.height <= refLuma.height*16 else { throw VP9DecodeError.malformed }
            func part(_ bx: Int, _ by: Int, _ w: Int, _ ht: Int, _ mv: VP9MV) {
                let at = VP9Plane.motionSource(frame:(h.width,h.height),reference:(refLuma.width,refLuma.height),cols:cols,rows:rows,
                                               subsampling:subsampling,col:col,row:row,blockWidth:width,blockHeight:height,
                                               bx:bx,by:by,width:w,height:ht,mv:mv)
                planes[plane].predictInter(reference:source.planes[plane],x:at.x,y:at.y,width:w,height:ht,
                    sourceX16:at.x16,sourceY16:at.y16,stepX16:at.stepX16,stepY16:at.stepY16,filter:block.filter,average:i == 1)
            }
            if let sub = block.subVectors {
                if plane == 0 {
                    for n in 0..<4 { part(n%2*4,n/2*4,4,4,i == 0 ? sub[n].0 : sub[n].1) }
                } else {
                    var rowSum = 0, colSum = 0
                    for n in 0..<4 { let v = i == 0 ? sub[n].0 : sub[n].1; rowSum += v.row; colSum += v.col }
                    func average(_ total: Int) -> Int { (total + (total < 0 ? -2 : 2))/4 }
                    part(0,0,width,height,.init(row:average(rowSum),col:average(colSum)))
                }
            } else { part(0,0,width,height,i == 0 ? block.vectors.0 : block.vectors.1) }
        }
    }
}

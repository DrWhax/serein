/// Per-MI neighbour state (8×8), including the four luma sub-blocks in decode order.
struct VP9MV: Equatable { var row = 0, col = 0 }
struct VP9Block {
    var width = 8, height = 8, tx = 0, segment = 0, level = 0
    var originX = 0, originY = 0
    var skip = false, predictedSegment = false
    var yModes = (0,0,0,0), uvMode = 0
    var refs = (0,0), motionMode = 0, filter = 4
    var vectors = (VP9MV(),VP9MV())
    var subVectors: [(VP9MV,VP9MV)]?
    func mode(_ x: Int, _ y: Int) -> Int {
        switch y*2+x { case 0: yModes.0; case 1: yModes.1; case 2: yModes.2; default: yModes.3 }
    }
}
final class VP9Picture {
    let cols, rows: Int
    var planes: [VP9Plane]
    var blocks: [VP9Block]
    init(width: Int, height: Int) {
        cols = (width+7)/8; rows = (height+7)/8
        planes = [VP9Plane(width:width, height:height),VP9Plane(width:(width+1)/2,height:(height+1)/2,chroma:true),VP9Plane(width:(width+1)/2,height:(height+1)/2,chroma:true)]
        blocks = [VP9Block](repeating: .init(), count: cols*rows)
    }
}

final class VP9Tile {
    let h: VP9Header, context: VP9Context, picture: VP9Picture
    let references: [VP9Picture?], previous: VP9Picture?
    let usePreviousMVs: Bool
    let left, right, top, bottom: Int
    var coder: VP9Boolean
    var partAbove, partLeft: [Int]
    var nzAbove, nzLeft: [[Int]]
    let refDelta: [Int], modeDelta: [Int]

    init(_ data: ArraySlice<UInt8>, h: VP9Header, context: VP9Context, picture: VP9Picture,
         references: [VP9Picture?], previous: VP9Picture?, usePreviousMVs: Bool, area: (Int,Int,Int,Int),
         refDelta: [Int], modeDelta: [Int]) throws {
        self.h = h; self.context = context; self.picture = picture; self.references = references; self.previous = previous
        self.usePreviousMVs = usePreviousMVs
        (left,right,top,bottom) = area
        self.refDelta = refDelta; self.modeDelta = modeDelta
        coder = try .init(data)
        partAbove = .init(repeating:0,count:picture.cols+8); partLeft = .init(repeating:0,count:picture.rows+8)
        nzAbove = .init(repeating: .init(repeating:0,count:picture.cols*2+16),count:3)
        nzLeft = .init(repeating: .init(repeating:0,count:picture.rows*2+16),count:3)
    }
    func neighbour(_ col: Int, _ row: Int) -> VP9Block? {
        guard col >= left, col < right, row >= 0, row < picture.rows else { return nil }
        return picture.blocks[row*picture.cols+col]
    }
    func decode() throws {
        for row in stride(from:top,to:bottom,by:8) {
            for col in stride(from:left,to:right,by:8) { try partition(col,row,level:3) }
        }
        guard !coder.exhausted else { throw VP9DecodeError.malformed }
    }
    func partition(_ col: Int, _ row: Int, level: Int) throws {
        guard col < right, row < bottom else { return }
        let size = 1 << level, half = size/2
        let hasRows = row+half < picture.rows, hasCols = col+half < picture.cols
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
            for y in [row,row+half] { for x in [col,col+half] { try partition(x,y,level:level-1) } }
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
    func block(_ col: Int, _ row: Int, width: Int, height: Int) throws {
        let above = neighbour(col,row-1), leftBlock = neighbour(col-1,row)
        var b = VP9Block(width:width, height:height)
        b.originX = col*8; b.originY = row*8
        let subs = min(width,height) < 8
        if h.segmented {
            var predicted = 7
            let old = h.intra || h.resilient ? nil : previous.flatMap { p in p.cols == picture.cols && p.rows == picture.rows ? p : nil }
            if let old {
                for y in row..<min(picture.rows,row+max(1,height/8)) {
                    for x in col..<min(picture.cols,col+max(1,width/8)) { predicted = min(predicted,old.blocks[y*old.cols+x].segment) }
                }
            } else { predicted = 0 }
            if !h.intra, h.updateMap, h.temporalMap {
                let at = (above?.predictedSegment == true ? 1 : 0)+(leftBlock?.predictedSegment == true ? 1 : 0)
                b.predictedSegment = coder.bit(h.segmentation.prediction[at]) != 0
            }
            if h.updateMap && !b.predictedSegment {
                b.segment = coder.tree([2,4,6,8,10,12,0,-1,-2,-3,-4,-5,-6,-7],probs:h.segmentation.tree,at:0)
            } else if !h.intra { b.segment = predicted }
        }
        let features = h.segmented ? h.segmentation.features[b.segment] : [nil,nil,nil,nil]
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
            let offset = [0,VP9Prob.tx8,VP9Prob.tx16,VP9Prob.tx32][maxTX]+ctx*maxTX
            b.tx = 0
            while b.tx < maxTX, context.read(&coder,offset+b.tx) != 0 { b.tx += 1 }
        }
        if inter {
            try interModes(col:col,row:row,block:&b,forcedRef:features[2],forcedSkip:features[3] != nil)
        } else {
            var modes = [Int](repeating:0,count:4)
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
                guard y < ((picture.rows*8) >> shift) else { break }
                for bx in stride(from:0,to:pw,by:size) {
                    let x = ox+bx
                    guard x < ((picture.cols*8) >> shift) else { break }
                    let mode = p == 0 ? b.mode(subs ? bx/4 : 1,subs ? by/4 : 1) : b.uvMode
                    if !inter {
                        picture.planes[p].predictIntra(mode:mode,x:x,y:y,size:size,tileLeft:(left*8) >> shift,tileTop:0,haveRight:bx+size<pw)
                    }
                    let span = size/4, ix = x/4, iy = y/4
                    var nonzero = false
                    if !b.skip {
                        let above = nzAbove[p][ix..<(ix+span)].contains(1), left = nzLeft[p][iy..<(iy+span)].contains(1)
                        let type = !inter && p == 0 && tx < 3 && !h.lossless ? [0,1,2,0,3,1,2,2,1,3][mode] : 0
                        var (values,tokens) = context.residual(&coder,tx:tx,type:type,chroma:p != 0,inter:inter,
                            neighbours:(above ? 1 : 0)+(left ? 1 : 0),dc:dc,ac:ac)
                        nonzero = tokens
                        if nonzero {
                            VP9Transform.apply(&values,size:size,type:type,lossless:h.lossless)
                            let stride = picture.planes[p].stride
                            for dy in 0..<size { for dx in 0..<size {
                                let pos = (y+dy)*stride+x+dx
                                picture.planes[p].bytes[pos] = UInt8(clamping:Int(picture.planes[p].bytes[pos])+values[dy*size+dx])
                            } }
                        }
                    }
                    hasTokens = hasTokens || nonzero
                    for i in 0..<span {
                        nzAbove[p][ix+i] = nonzero && ix+i < ((picture.cols*2) >> shift) ? 1 : 0
                        nzLeft[p][iy+i] = nonzero && iy+i < ((picture.rows*2) >> shift) ? 1 : 0
                    }
                }
            }
        }
        // libvpx feeds a zero-EOB inter block of at least 8×8 back into both
        // the next block's skip probability and the loop filter.
        b.skip = b.skip || (inter && !subs && !hasTokens)
        for y in row..<min(bottom,row+max(1,height/8)) { for x in col..<min(right,col+max(1,width/8)) {
            picture.blocks[y*picture.cols+x] = b
        } }
        if coder.exhausted { throw VP9DecodeError.malformed }
    }
}

extension VP9Tile {
    func predictInter(col: Int, row: Int, plane: Int, block: VP9Block) throws {
        let subsampling = plane == 0 ? 0 : 1
        let x = (col*8) >> subsampling, y = (row*8) >> subsampling
        let width = max(8,block.width) >> subsampling, height = max(8,block.height) >> subsampling
        for i in 0..<(block.refs.1 == 0 ? 1 : 2) {
            let ref = i == 0 ? block.refs.0 : block.refs.1
            guard (1...3).contains(ref), let source = references[h.references[ref-1]] else { throw VP9DecodeError.missingReference }
            let refLuma = source.planes[0]
            guard refLuma.width <= h.width*2, refLuma.height <= h.height*2,
                  h.width <= refLuma.width*16, h.height <= refLuma.height*16 else { throw VP9DecodeError.malformed }
            let scaleX = (refLuma.width << 14)/h.width, scaleY = (refLuma.height << 14)/h.height
            let sx = (scaleX*16) >> 14, sy = (scaleY*16) >> 14
            func part(_ bx: Int, _ by: Int, _ w: Int, _ ht: Int, _ mv: VP9MV) {
                var dx = mv.col << (1-subsampling), dy = mv.row << (1-subsampling)
                if scaleX != 16384 || scaleY != 16384 {
                    let marginX = (4+w)*16, marginY = (4+ht)*16
                    dx = max(-x*16-marginX,min(dx,(((picture.cols*8) >> subsampling)-x-width)*16+marginX-16))
                    dy = max(-y*16-marginY,min(dy,(((picture.rows*8) >> subsampling)-y-height)*16+marginY-16))
                }
                let ix = x+bx, iy = y+by
                let originX = (((ix*scaleX) >> 14) << 4) + (((scaleX*((col*8+bx)*16)) >> 14) & 15)
                let originY = (((iy*scaleY) >> 14) << 4) + (((scaleY*((row*8+by)*16)) >> 14) & 15)
                picture.planes[plane].predictInter(reference:source.planes[plane],x:ix,y:iy,width:w,height:ht,
                    sourceX16:originX+((scaleX*dx) >> 14),sourceY16:originY+((scaleY*dy) >> 14),
                    stepX16:sx,stepY16:sy,filter:block.filter,average:i == 1)
            }
            if let sub = block.subVectors {
                guard sub.count == 4 else { throw VP9DecodeError.malformed }
                if plane == 0 {
                    for n in 0..<4 { part(n%2*4,n/2*4,4,4,i == 0 ? sub[n].0 : sub[n].1) }
                } else {
                    let v = sub.map { i == 0 ? $0.0 : $0.1 }
                    func average(_ total: Int) -> Int { (total + (total < 0 ? -2 : 2))/4 }
                    part(0,0,width,height,.init(row:average(v.reduce(0) { $0+$1.row }),col:average(v.reduce(0) { $0+$1.col })))
                }
            } else { part(0,0,width,height,i == 0 ? block.vectors.0 : block.vectors.1) }
        }
    }
}

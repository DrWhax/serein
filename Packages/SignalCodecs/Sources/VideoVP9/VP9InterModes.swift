// VP9 Bitstream Specification, sections 6.4.9–6.4.14 and 7.3.
// Reference tables and context derivations from libvpx (BSD-3-Clause).
extension VP9Block {
    var compound: Bool { refs.1 != 0 }
    var inter: Bool { refs.0 != 0 }
    func uses(_ reference: Int) -> Bool { refs.0 == reference || refs.1 == reference }
}

struct VP9References {
    let edges: [VP9Block]
    let fixed: Int, first: Int, second: Int
    let fixedLast: Bool

    init(_ above: VP9Block?, _ left: VP9Block?, bias: [Bool]) {
        edges = [above, left].compactMap { $0 }
        if bias[1] == bias[2] { (fixed, first, second) = (3,1,2) }
        else if bias[1] == bias[3] { (fixed, first, second) = (2,1,3) }
        else { (fixed, first, second) = (1,2,3) }
        fixedLast = bias[fixed]
    }

    var mode: Int {
        guard let a = edges.first else { return 1 }
        guard edges.count == 2 else { return a.compound ? 3 : (a.refs.0 == fixed ? 1 : 0) }
        let b = edges[1]
        if !a.compound && !b.compound { return (a.refs.0 == fixed) != (b.refs.0 == fixed) ? 1 : 0 }
        if a.compound && b.compound { return 4 }
        let single = a.compound ? b : a
        return (single.refs.0 == fixed || !single.inter) ? 3 : 2
    }

    var variable: Int {
        func selected(_ b: VP9Block) -> Int { b.compound && !fixedLast ? b.refs.1 : b.refs.0 }
        let inter = edges.filter(\.inter)
        guard let a = inter.first else { return 2 }
        let ar = selected(a)
        if inter.count == 1 {
            if edges.count == 2 { return ar == second ? 1 : 3 }
            return ar == second ? 0 : (a.compound ? 4 : 3)
        }
        let b = inter[1], br = selected(b)
        if ar == br && ar == second { return 0 }
        if a.compound && b.compound { return ar == br ? 4 : 2 }
        if !a.compound && !b.compound {
            if (ar == fixed && br == first) || (br == fixed && ar == first) { return 4 }
            return ar == br ? 3 : 1
        }
        let compound = a.compound ? ar : br, single = a.compound ? br : ar
        if compound == second { return 1 }
        return single == second ? 2 : 4
    }

    func single(_ target: Int) -> Int {
        let inter = edges.filter(\.inter)
        guard let a = inter.first else { return 2 }
        let ap = a.uses(target) ? 1 : 0
        if inter.count == 1 {
            if target == 1 { return a.compound ? 1 + ap : 4 * ap }
            if a.compound { return edges.count == 1 ? 3 * ap : 1 + 2 * ap }
            return a.refs.0 == 1 ? (edges.count == 1 ? 2 : 3) : 4 * ap
        }
        let b = inter[1], bp = b.uses(target) ? 1 : 0
        if a.compound && b.compound {
            if target == 1 { return 1 + max(ap,bp) }
            return a.refs == b.refs ? 3 * ap : 2
        }
        if a.compound || b.compound {
            let single = a.compound ? b.refs.0 : a.refs.0
            let has = a.compound ? ap : bp
            if single == target { return 3 + has }
            if target == 2 && single == 1 { return 1 + 2 * has }
            return has
        }
        if target == 2 {
            if a.refs.0 == 1 && b.refs.0 == 1 { return 3 }
            if a.refs.0 == 1 || b.refs.0 == 1 { return 4 * (ap + bp) }
        }
        return 2 * (ap + bp)
    }
}

/// Motion vector prediction shared by the decoder (VP9Tile) and the encoder: neighbour
/// candidates (libvpx find_mv_refs), the inter-mode context and precision lowering.
/// `neighbour(col, row)` returns a coded block of the same tile, or nil.
enum VP9VectorPrediction {
    private static let modeContexts = [2,3,4,1,3,0,0,0,0,5,5,0,5,0,0,0,0,0,6]
    private static let modeWeights = [0,0,3,1]

    // Neighbours for each block size in (row, column) order.
    static func offsets(width: Int, height: Int) -> [(Int,Int)] {
        switch (width,height) {
        case (8,16): [(0,-1),(-1,0),(1,-1),(-1,-1),(0,-2),(-2,0),(-2,-1),(-1,-2)]
        case (16,8): [(-1,0),(0,-1),(-1,1),(-1,-1),(-2,0),(0,-2),(-1,-2),(-2,-1)]
        case (16,16): [(-1,0),(0,-1),(-1,1),(1,-1),(-1,-1),(-3,0),(0,-3),(-3,-3)]
        case (16,32): [(0,-1),(-1,0),(2,-1),(-1,-1),(-1,1),(0,-3),(-3,0),(-3,-3)]
        case (32,16): [(-1,0),(0,-1),(-1,2),(-1,-1),(1,-1),(-3,0),(0,-3),(-3,-3)]
        case (32,32): [(-1,1),(1,-1),(-1,2),(2,-1),(-1,-1),(-3,0),(0,-3),(-3,-3)]
        case (32,64): [(0,-1),(-1,0),(4,-1),(-1,2),(-1,-1),(0,-3),(-3,0),(2,-1)]
        case (64,32): [(-1,0),(0,-1),(-1,4),(2,-1),(-1,-1),(-3,0),(0,-3),(-1,2)]
        case (64,64): [(-1,3),(3,-1),(-1,4),(4,-1),(-1,-1),(-1,0),(0,-1),(-1,6)]
        default: [(-1,0),(0,-1),(-1,-1),(-2,0),(0,-2),(-2,-1),(-1,-2),(-2,-2)]
        }
    }

    /// The inter-mode probability context: from the first two neighbours' modes.
    static func modeContext(col: Int, row: Int, offsets: [(Int,Int)], neighbour: (Int, Int) -> VP9Block?) -> Int {
        var tally = 0
        for (dy, dx) in offsets.prefix(2) {
            if let edge = neighbour(col+dx,row+dy) { tally += edge.refs.0 != 0 ? modeWeights[edge.motionMode] : 9 }
        }
        return modeContexts[tally]
    }

    /// Nearest (and near) vector candidates for `reference`, clamped as the decoder clamps them.
    /// `previous`: the co-located block of the previous picture, when its vectors are used.
    static func candidates(col: Int, row: Int, block: VP9Block, reference: Int, sub: Int, near: Bool,
                           offsets: [(Int,Int)], bias: [Bool], rows: Int, cols: Int, previous: VP9Block?,
                           neighbour: (Int, Int) -> VP9Block?) -> [VP9MV] {
        var sources: [(block: VP9Block, subIndex: Int?)] = []
        for (i, offset) in offsets.enumerated() {
            if let other = neighbour(col + offset.1, row + offset.0) {
                var subIndex: Int?
                if i < 2, sub >= 0, other.subVectors != nil {
                    subIndex = offset.1 == 0 ? [2,3,2,3][sub] : [1,1,3,3][sub]
                }
                sources.append((other,subIndex))
            }
        }
        if let previous { sources.append((previous,nil)) }
        let wantedCount = near ? 2 : 1
        var vectors: [VP9MV] = []
        func add(_ mv: VP9MV) { if vectors.count < wantedCount && !vectors.contains(mv) { vectors.append(mv) } }
        for source in sources {
            guard vectors.count < wantedCount else { break }
            let pair = source.subIndex.flatMap { source.block.subVectors?[$0] } ?? source.block.vectors
            if source.block.refs.0 == reference { add(pair.0) }
            else if source.block.refs.1 == reference { add(pair.1) }
        }
        for source in sources {
            guard vectors.count < wantedCount else { break }
            let other = source.block
            for i in 0..<(other.refs.1 != 0 ? 2 : 1) {
                let ref = i == 0 ? other.refs.0 : other.refs.1
                guard ref > 0 && ref != reference, i == 0 || other.vectors.0 != other.vectors.1 else { continue }
                var mv = i == 0 ? other.vectors.0 : other.vectors.1
                if bias[ref] != bias[reference] { mv = VP9MV(row: -mv.row, col: -mv.col) }
                add(mv)
            }
        }
        while vectors.count < wantedCount { vectors.append(VP9MV()) }
        let maxRow = (rows - row - max(1,block.height/8)) * 64 + 128
        let maxCol = (cols - col - max(1,block.width/8)) * 64 + 128
        return vectors.map { VP9MV(row: max(-row*64-128,min(maxRow,$0.row)), col: max(-col*64-128,min(maxCol,$0.col))) }
    }

    /// Without high precision (or for a long reference), vectors keep quarter samples.
    static func lowerPrecision(_ mv: VP9MV, highPrecision: Bool) -> VP9MV {
        if highPrecision && abs(mv.row) < 64 && abs(mv.col) < 64 { return mv }
        return VP9MV(row: mv.row / 2 * 2, col: mv.col / 2 * 2)
    }
}

extension VP9Tile {
    private static let modeTree = [-2, 2, 0, 4, -1, -3]
    private static let fourValues = [0,2,-1,4,-2,-3]
    private static let classTree = [0,2,-1,4,6,8,-2,-3,10,12,-4,-5,-6,14,16,18,-7,-8,-9,-10]

    private mutating func mvComponent(_ axis: Int, highPrecision: Bool) -> Int {
        let neg = context.read(&coder, VP9Prob.sign + axis)
        let cls = context.tree(&coder, Self.classTree, VP9Prob.mvClass + 10 * axis)
        var delta = 0
        if cls == 0 { delta = context.read(&coder, VP9Prob.class0 + axis) }
        else {
            for bit in 0..<cls { delta |= context.read(&coder, VP9Prob.mvBits + 10 * axis + bit) << bit }
        }
        let index = cls == 0 ? VP9Prob.class0Fr + 6 * axis + 3 * delta : VP9Prob.mvFr + 3 * axis
        let fraction = context.tree(&coder, Self.fourValues, index)
        // libvpx vp9_inc_mv counts the high-precision bit as 1 even when this vector cannot read
        // it (a large reference). It adapts those probabilities only in frames that allow high
        // precision (vp9_adapt_mv_probs), and adapt() follows the counts, so count only there.
        let hpIndex = (cls == 0 ? VP9Prob.class0HP : VP9Prob.hp) + axis
        let hp: Int
        if highPrecision { hp = context.read(&coder, hpIndex) } else {
            hp = 1
            if h.highPrecision { context.count(hpIndex, 1) }
        }
        let magnitude = (cls == 0 ? 0 : 2 << (cls + 2)) + (delta << 3) + 2 * fraction + hp + 1
        return neg == 0 ? magnitude : -magnitude
    }

    private mutating func differential(_ base: VP9MV) throws -> VP9MV {
        let joint = context.tree(&coder, Self.fourValues, VP9Prob.joint)
        let hp = h.highPrecision && abs(base.row) < 64 && abs(base.col) < 64
        let row = base.row + (joint >= 2 ? mvComponent(0, highPrecision: hp) : 0)
        let col = base.col + (joint & 1 == 1 ? mvComponent(1, highPrecision: hp) : 0)
        guard (-16_383..<16_383).contains(row) && (-16_383..<16_383).contains(col) else { throw VP9DecodeError.malformed }
        return VP9MV(row: row, col: col)
    }

    private mutating func referencePair(_ hints: VP9References, forced: Int?) -> (Int,Int) {
        if let forced { return (forced,0) }
        let compound = context.refMode == 2 ? context.read(&coder, VP9Prob.compound + hints.mode) : context.refMode
        if compound != 0 {
            let second = context.read(&coder, VP9Prob.compoundRef + hints.variable) == 0 ? hints.first : hints.second
            return hints.fixedLast ? (second,hints.fixed) : (hints.fixed,second)
        }
        if context.read(&coder, VP9Prob.singleRef + 2 * hints.single(1)) == 0 { return (1,0) }
        return (2 + context.read(&coder, VP9Prob.singleRef + 2 * hints.single(2) + 1),0)
    }

    mutating func interModes(col: Int, row: Int, block: inout VP9Block, forcedRef: Int?, forcedSkip: Bool) throws {
        let above = neighbour(col,row-1), left = neighbour(col-1,row)
        block.refs = referencePair(VP9References(above,left,bias:h.bias), forced: forcedRef)
        let offsets = VP9VectorPrediction.offsets(width: block.width, height: block.height)
        let modeProb = VP9Prob.interMode + 3 * VP9VectorPrediction.modeContext(col: col, row: row, offsets: offsets) { neighbour($0,$1) }
        let subBlocks = min(block.width,block.height) < 8
        if forcedSkip {
            guard !subBlocks else { throw VP9DecodeError.malformed }
            block.motionMode = 2
        } else if !subBlocks { block.motionMode = context.tree(&coder, Self.modeTree, modeProb) }
        block.filter = h.filter
        if h.filter == 4 {
            let a = above.flatMap { $0.inter ? $0.filter : nil } ?? 3
            let b = left.flatMap { $0.inter ? $0.filter : nil } ?? 3
            let filterContext = a == b || b == 3 ? a : (a == 3 ? b : 3)
            block.filter = context.tree(&coder, [0,2,-1,-2], VP9Prob.interp + 2 * min(3,filterContext))
        }
        if subBlocks { block.subVectors = VP9SubVectors() }
        for y in stride(from: 0, to: 2, by: min(2,block.height/4)) {
            for x in stride(from: 0, to: 2, by: min(2,block.width/4)) {
                let sub = 2*y+x
                if subBlocks { block.motionMode = context.tree(&coder, Self.modeTree, modeProb) }
                var pair = (VP9MV(),VP9MV())
                for channel in 0..<(block.compound ? 2 : 1) where block.motionMode != 2 {
                    let reference = channel == 0 ? block.refs.0 : block.refs.1
                    let new = block.motionMode == 3, near = block.motionMode == 1
                    let previousBlock = usePreviousMVs ? previous.flatMap { p in row < p.rows && col < p.cols ? p.blocks[row * p.cols + col] : nil } : nil
                    let external = VP9VectorPrediction.candidates(col: col, row: row, block: block, reference: reference,
                                                                  sub: subBlocks && !new ? sub : -1, near: near, offsets: offsets,
                                                                  bias: h.bias, rows: rows, cols: cols, previous: previousBlock) { neighbour($0,$1) }
                    var best = near ? external[1] : external[0]
                    if let parts = block.subVectors, !new, sub > 0 {
                        func at(_ i: Int) -> VP9MV { channel == 0 ? parts[i].0 : parts[i].1 }
                        let nearest = at(sub == 3 ? 2 : 0)
                        if near {
                            let alternatives = sub == 3 ? [at(1),at(0)] + external : external
                            best = alternatives.first { $0 != nearest } ?? VP9MV()
                        } else { best = nearest }
                    }
                    if !subBlocks || new { best = VP9VectorPrediction.lowerPrecision(best, highPrecision: h.highPrecision) }
                    let mv = new ? try differential(best) : best
                    if channel == 0 { pair.0 = mv } else { pair.1 = mv }
                }
                block.vectors = pair
                if subBlocks {
                    block.subVectors?[sub] = pair
                    if block.width == 8 { block.subVectors?[sub+1] = pair }
                    if block.height == 8 { block.subVectors?[sub+2] = pair }
                }
            }
        }
    }
}

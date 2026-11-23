/// Boolean range coder for VP9 compressed headers and tile partitions.
struct VP9Boolean {
    let bytes: ArraySlice<UInt8>
    private var pos: Int, available = 0, range = 255
    private var value: UInt64 = 0
    var exhausted: Bool { available < 0 }

    init(_ bytes: ArraySlice<UInt8>) throws {
        self.bytes = bytes
        pos = bytes.startIndex
        fill()
        guard !bytes.isEmpty, bit() == 0 else { throw VP9DecodeError.malformed }
    }
    private mutating func fill() {
        while available <= 56, pos < bytes.endIndex {
            value |= UInt64(bytes[pos]) << (56-available)
            pos += 1
            available += 8
        }
    }
    mutating func bit(_ probability: Int = 128) -> Int {
        let split = 1 + (((range-1)*probability) >> 8), boundary = UInt64(split) << 56
        let one = value >= boundary
        if one { value -= boundary; range -= split } else { range = split }
        let shift = UInt8(range).leadingZeroBitCount
        range <<= shift
        value <<= shift
        available -= shift
        if available <= 56 { fill() }
        return one ? 1 : 0
    }
    mutating func literal(_ count: Int) -> Int {
        var v = 0
        for _ in 0..<count { v = v*2 + bit() }
        return v
    }
    mutating func tree(_ shape: [Int], probs: [Int], at start: Int) -> Int {
        var node = 0
        repeat { node = shape[node + bit(probs[start+node/2])] } while node > 0
        return -node
    }
    mutating func updated(_ p: Int, motion: Bool) -> Int {
        guard bit(252) != 0 else { return p }
        if motion { return literal(7)*2+1 }
        let v: Int
        if bit() == 0 { v = literal(4) }
        else if bit() == 0 { v = 16+literal(4) }
        else if bit() == 0 { v = 32+literal(5) }
        else { let n = literal(7); v = 64 + (n < 65 ? n : 2*n-65+bit()) }
        let x = VP9Table.invMapTable[v], m = p-1
        func recenter(_ center: Int) -> Int {
            x > center*2 ? x : (x % 2 == 0 ? center+x/2 : center-(x+1)/2)
        }
        return m*2 <= 255 ? 1+recenter(m) : 255-recenter(254-m)
    }
}

enum VP9Prob {
    static let tx8 = 0, tx16 = 2, tx32 = 6, skip = 12, interMode = 15, interp = 36, isInter = 44
    static let compound = 48, singleRef = 53, compoundRef = 63, yMode = 68, uvMode = 104, partition = 194
    static let joint = 242, sign = 245, mvClass = 247, class0 = 267, mvBits = 269, class0Fr = 289
    static let mvFr = 301, class0HP = 307, hp = 309, coef = 311
    static let initial: [Int] = [
        VP9Table.txProbs8,VP9Table.txProbs16,VP9Table.txProbs32,VP9Table.skipProbs,
        VP9Table.interModeProbs,VP9Table.interpFilterProbs,VP9Table.isInterProbs,VP9Table.compInterProbs,
        VP9Table.singleRefProbs,VP9Table.compRefProbs,VP9Table.YModeProbs,VP9Table.UVModeProbs,
        VP9Table.partitionProbs,VP9Table.MVJointProbs,VP9Table.MVSignProbs,VP9Table.MVClassProbs,
        VP9Table.MVClass0BitProbs,VP9Table.MVBitsProbs,VP9Table.MVClass0FrProbs,VP9Table.MVFrProbs,
        VP9Table.MVClass0HPProbs,VP9Table.MVHPProbs,VP9Table.coefProbs
    ].flatMap { $0 }
}

final class VP9Context {
    var probabilities: [Int]
    var counts: [Int]
    var txMode = 0, refMode = 0
    init(_ probs: [Int]) {
        probabilities = probs
        counts = .init(repeating: 0, count: 2*probs.count)
    }
    func read(_ coder: inout VP9Boolean, _ i: Int) -> Int {
        let b = coder.bit(probabilities[i])
        counts[2*i+b] += 1
        return b
    }
    /// A read that libvpx does not count as read (it counts the decoded symbol instead).
    func peek(_ coder: inout VP9Boolean, _ i: Int) -> Int { coder.bit(probabilities[i]) }
    func count(_ i: Int, _ bit: Int) { counts[2*i+bit] += 1 }
    /// libvpx read_partition counts the resulting partition, ++counts->partition[ctx][p], even
    /// where the picture edge leaves one bit or none to read; adaptation then sees the symbol's
    /// whole tree path: NONE 0; HORZ 1,0; VERT 1,1,0; SPLIT 1,1,1.
    func countPartition(_ base: Int, _ type: Int) {
        count(base, type == 0 ? 0 : 1)
        if type > 0 { count(base + 1, type == 1 ? 0 : 1) }
        if type > 1 { count(base + 2, type == 2 ? 0 : 1) }
    }
    func tree(_ coder: inout VP9Boolean, _ shape: [Int], _ start: Int) -> Int {
        var node = 0
        repeat { node = shape[node + read(&coder,start+node/2)] } while node > 0
        return -node
    }
    func decodeHeader(_ input: ArraySlice<UInt8>, header: VP9Header) throws {
        var coder = try VP9Boolean(input)
        if !header.lossless { txMode = coder.literal(2); if txMode == 3 { txMode += coder.bit() } }
        func update(_ start: Int, _ count: Int, motion: Bool = false) {
            for i in start..<(start+count) { probabilities[i] = coder.updated(probabilities[i], motion: motion) }
        }
        if txMode == 4 { update(VP9Prob.tx8,12) }
        for tx in 0...min(txMode,3) where coder.bit() != 0 {
            for plane in 0..<2 { for ref in 0..<2 { for band in 0..<6 {
                let at = VP9Prob.coef+(((tx*2+plane)*2+ref)*6+band)*18
                update(at, band == 0 ? 9 : 18)
            } } }
        }
        update(VP9Prob.skip,3)
        if !header.intra {
            update(VP9Prob.interMode,21)
            if header.filter == 4 { update(VP9Prob.interp,8) }
            update(VP9Prob.isInter,4)
            if header.bias[1] != header.bias[2] || header.bias[1] != header.bias[3] {
                if coder.bit() != 0 { refMode = 1 + coder.bit() }
            }
            if refMode == 2 { update(VP9Prob.compound,5) }
            if refMode != 1 { update(VP9Prob.singleRef,10) }
            if refMode != 0 { update(VP9Prob.compoundRef,5) }
            update(VP9Prob.yMode,36)
            update(VP9Prob.partition,48)
            update(VP9Prob.joint,3,motion:true)
            for c in 0..<2 {
                update(VP9Prob.sign+c,1,motion:true)
                update(VP9Prob.mvClass+c*10,10,motion:true)
                update(VP9Prob.class0+c,1,motion:true)
                update(VP9Prob.mvBits+c*10,10,motion:true)
            }
            for c in 0..<2 {
                update(VP9Prob.class0Fr+c*6,6,motion:true)
                update(VP9Prob.mvFr+c*3,3,motion:true)
            }
            if header.highPrecision {
                for c in 0..<2 {
                    update(VP9Prob.class0HP+c,1,motion:true)
                    update(VP9Prob.hp+c,1,motion:true)
                }
            }
        }
        guard !coder.exhausted else { throw VP9DecodeError.malformed }
    }
    func adapt(from previous: [Int], intra: Bool, afterKey: Bool) {
        for i in probabilities.indices where !intra || i >= VP9Prob.coef {
            let zeros = counts[i*2], total = zeros+counts[i*2+1]
            if total == 0 { probabilities[i] = previous[i]; continue }
            let sample = max(1,min(255,(256*zeros + total/2)/total))
            let factor: Int
            if i >= VP9Prob.coef { factor = (afterKey && !intra ? 128 : 112)*min(24,total)/24 }
            else { factor = [0,6,12,19,25,32,38,44,51,57,64,70,76,83,89,96,102,108,115,121,128][min(20,total)] }
            probabilities[i] = (previous[i]*(256-factor)+sample*factor+128) >> 8
        }
    }
}

extension VP9Context {
    /// Coefficient model (tx size, chroma, inter, band, neighbours, tree node). Dequantised
    /// values go into `coefficients` and token classes into `energy`, both all zero on entry;
    /// energy is zero again on return. True if any token was read.
    func residual(_ coder: inout VP9Boolean, tx: Int, type: Int, chroma: Bool, inter: Bool,
                  neighbours: Int, dc: Int, ac: Int, coefficients: inout [Int], energy: inout [UInt8]) -> Bool {
        // Counted reads use local copies: no exclusivity or uniqueness checks per symbol.
        var counts = [Int]()
        swap(&counts, &self.counts)
        let probabilities = self.probabilities
        var tally = counts.mutableSpan
        var values = coefficients.mutableSpan, tokens = energy.mutableSpan
        let read = Self.tokens(&coder, probabilities.span, &tally, tx: tx, type: type, chroma: chroma, inter: inter,
                               neighbours: neighbours, dc: dc, ac: ac, &values, &tokens)
        swap(&counts, &self.counts)
        return read
    }

    private static func tokens(_ coder: inout VP9Boolean, _ probabilities: borrowing Span<Int>, _ counts: inout MutableSpan<Int>,
                               tx: Int, type: Int, chroma: Bool, inter: Bool, neighbours: Int, dc: Int, ac: Int,
                               _ coefficients: inout MutableSpan<Int>, _ energy: inout MutableSpan<UInt8>) -> Bool {
        @inline(__always) func read(_ coder: inout VP9Boolean, _ counts: inout MutableSpan<Int>, _ i: Int) -> Int {
            let b = coder.bit(probabilities[i])
            counts[2*i+b] += 1
            return b
        }
        let scans = Self.scans[min(tx,3)][type == 1 && tx < 3 ? 1 : (type == 2 && tx < 3 ? 2 : 0)]
        let (scan, adjacent) = scans
        let limit = scan.count
        let row = VP9Prob.coef+((tx*2+(chroma ? 1 : 0))*2+(inter ? 1 : 0))*108
        var pos = 0, context = neighbours, readEnd = true
        let bands = tx == 0 ? Self.bands4 : Self.bandsLarge
        let table = VP9Table.pareto8Full
        while pos < limit {
            let band = pos < bands.count ? bands[pos] : 5
            let p = row + band*18 + context*3
            if readEnd, read(&coder,&counts,p) == 0 { break }
            let index = scan[pos]
            if read(&coder,&counts,p+1) == 0 {
                readEnd = false
            } else {
                var value = 1, token: UInt8 = 1
                if read(&coder,&counts,p+2) != 0 {
                    let base = (probabilities[p+2]-1)*8
                    if coder.bit(table[base]) == 0 {
                        if coder.bit(table[base+1]) == 0 { value = 2; token = 2 }
                        else { value = 3+coder.bit(table[base+2]); token = 3 }
                    } else {
                        let cat: Int
                        if coder.bit(table[base+3]) == 0 { cat = coder.bit(table[base+4]); token = 4 }
                        else {
                            token = 5
                            if coder.bit(table[base+5]) == 0 { cat = 2+coder.bit(table[base+6]) }
                            else { cat = 4+coder.bit(table[base+7]) }
                        }
                        var extra = 0
                        for prob in Self.category[cat] { extra = extra*2 + coder.bit(prob) }
                        value = Self.categoryBase[cat] + extra
                    }
                }
                let scaled = (value * (index == 0 ? dc : ac)) >> (tx == 3 ? 1 : 0)
                coefficients[index] = Int(Int16(truncatingIfNeeded: coder.bit() == 0 ? scaled : -scaled))
                energy[index] = token
                readEnd = true
            }
            pos += 1
            if pos < limit { context = (1 + Int(energy[adjacent[2*pos]]) + Int(energy[adjacent[2*pos+1]])) >> 1 }
        }
        for k in 0..<pos { energy[scan[k]] = 0 }
        return pos > 0
    }
    private static let categoryBase = [5,7,11,19,35,67]
    private static let bands4 = [0,1,1,2,2,2,3,3,3,3,4,4,4]
    private static let bandsLarge = [0,1,1,2,2,2,3,3,3,3,4,4,4,4,4,4,4,4,4,4,4]
    private static let category = [[159],[165,145],[173,148,140],[176,155,140,135],[180,157,141,134,130],
                                   [254,254,254,252,249,243,230,196,177,153,140,133,130,129]]
    private static let scans: [[([Int],[Int])]] = [
        [(VP9Table.defaultScan4x4,VP9Table.defaultScanNb4x4),(VP9Table.rowScan4x4,VP9Table.rowScanNb4x4),(VP9Table.colScan4x4,VP9Table.colScanNb4x4)],
        [(VP9Table.defaultScan8x8,VP9Table.defaultScanNb8x8),(VP9Table.rowScan8x8,VP9Table.rowScanNb8x8),(VP9Table.colScan8x8,VP9Table.colScanNb8x8)],
        [(VP9Table.defaultScan16x16,VP9Table.defaultScanNb16x16),(VP9Table.rowScan16x16,VP9Table.rowScanNb16x16),(VP9Table.colScan16x16,VP9Table.colScanNb16x16)],
        [(VP9Table.defaultScan32x32,VP9Table.defaultScanNb32x32)]
    ]
}

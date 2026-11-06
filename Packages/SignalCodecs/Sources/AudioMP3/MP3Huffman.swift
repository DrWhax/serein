// The encoder's side of Layer III noiseless coding (11172-3 2.4.2.7, Annex C.1.5.4.4): the
// big-values / count1 / zero partition of the 576 quantised lines, Huffman table choice per
// region (the cheapest table that can code the region's largest value), the region0/region1
// split (exhaustive over region0_count × region1_count for long blocks), count1 table A or
// B, and the bit writer for all of it. Uses the decoder's tables in reverse.

import CodecCore

struct MP3HuffmanEncoder: Sendable {
    /// Per FFmpeg table index 1…15: code and length by symbol x·16 + y.
    static let codes: [[UInt32]] = (0 ..< 16).map { i in
        var c = [UInt32](repeating: 0, count: 256)
        guard i > 0 else { return c }
        for (j, s) in MP3Tables.huffSymbols[i].enumerated() { c[s] = MP3Tables.huffCodes[i][j] }
        return c
    }
    static let lengths: [[UInt8]] = (0 ..< 16).map { i in
        var l = [UInt8](repeating: 0, count: 256)
        guard i > 0 else { return l }
        for (j, s) in MP3Tables.huffSymbols[i].enumerated() { l[s] = MP3Tables.huffLengths[i][j] }
        return l
    }
    /// The largest value a table_select codes without linbits (15 with linbits = escape).
    static let maxValue: [Int] = (0 ..< 32).map { ts in
        let t = Int(MP3Tables.huffTable[ts])
        guard t > 0 else { return 0 }
        return MP3Tables.huffSymbols[t].map { max($0 >> 4, $0 & 15) }.max() ?? 0
    }

    /// Candidate table_selects for a region whose largest |value| is `m`.
    static func candidates(_ m: Int) -> [Int] {
        switch m {
        case 0: return [0]
        case 1: return [1]
        case 2: return [2, 3]
        case 3: return [5, 6]
        case 4, 5: return [7, 8, 9]
        case 6, 7: return [10, 11, 12]
        case 8 ... 15: return [13, 15]
        default:
            var out: [Int] = []
            for family in [16, 24] {
                for ts in family ..< family + 8 where m - 15 < 1 << Int(MP3Tables.huffLinbits[ts]) {
                    out.append(ts); break
                }
            }
            return out
        }
    }

    /// Bits for lines [a, b) (pairs) with table_select `ts`.
    static func bits(_ ix: [Int], _ a: Int, _ b: Int, table ts: Int) -> Int {
        let t = Int(MP3Tables.huffTable[ts]), lb = Int(MP3Tables.huffLinbits[ts])
        guard t > 0 else { return 0 }
        let len = lengths[t]
        var n = 0
        var i = a
        while i < b {
            let x = abs(ix[i]), y = abs(ix[i + 1])
            let ex = min(x, 15), ey = min(y, 15)
            n += Int(len[ex << 4 | ey])
            if x != 0 { n += 1 }
            if y != 0 { n += 1 }
            if lb > 0 {
                if x >= 15 { n += lb }
                if y >= 15 { n += lb }
            }
            i += 2
        }
        return n
    }

    /// The cheapest table for a region and its bits.
    static func bestTable(_ ix: [Int], _ a: Int, _ b: Int) -> (table: Int, bits: Int) {
        guard b > a else { return (0, 0) }
        var m = 0
        for i in a ..< b { m = max(m, abs(ix[i])) }
        var best = (table: 0, bits: Int.max)
        for ts in candidates(m) {
            let n = bits(ix, a, b, table: ts)
            if n < best.bits { best = (ts, n) }
        }
        return best
    }

    struct Layout: Sendable {
        var bigValues = 0          // pairs
        var count1End = 0          // lines
        var tableSelect = [0, 0, 0]
        var region0Count = 0, region1Count = 0
        var count1Table = 0
        var bits = 0
    }

    /// With window switching (block types 1, 2, 3) region0 is implicit (2.4.2.7: 36 lines,
    /// LSF start/stop 54, ×2 at 8 kHz) and region1 takes the rest of the big values.
    static func implicitRegion0(blockType: Int, sampleRateIndex r: Int) -> Int {
        blockType == 2 ? (r == 8 ? 72 : 36) : (r <= 2 ? 36 : r != 8 ? 54 : 108)
    }

    /// Partitions and codes the lines.
    static func layout(_ ix: [Int], blockType: Int, sampleRateIndex r: Int) -> Layout {
        var L = Layout()
        var i = 576
        while i > 1 && ix[i - 1] == 0 && ix[i - 2] == 0 { i -= 2 }
        L.count1End = i
        while i > 3 && abs(ix[i - 1]) <= 1 && abs(ix[i - 2]) <= 1 && abs(ix[i - 3]) <= 1 && abs(ix[i - 4]) <= 1 { i -= 4 }
        let big = i
        L.bigValues = big / 2
        // count1 table.
        var bitsA = 0, bitsB = 0
        var q = big
        while q < L.count1End {
            let v = (abs(ix[q]) << 3) | (abs(ix[q + 1]) << 2) | (abs(ix[q + 2]) << 1) | abs(ix[q + 3])
            let signs = v.nonzeroBitCount
            bitsA += Int(MP3Tables.quadBits[0][v]) + signs
            bitsB += 4 + signs
            q += 4
        }
        L.count1Table = bitsB < bitsA ? 1 : 0
        let count1Bits = min(bitsA, bitsB)
        if blockType != 0 {
            let r0 = min(big, implicitRegion0(blockType: blockType, sampleRateIndex: r))
            let a = bestTable(ix, 0, r0), b = bestTable(ix, r0, big)
            L.tableSelect = [a.table, b.table, 0]
            L.bits = a.bits + b.bits + count1Bits
            return L
        }
        let index = MP3Decoder.bandIndexLong[r]
        var best = (bits: Int.max, r0: 0, r1: 0, t: [0, 0, 0])
        for r0c in 0 ..< 16 {
            let e0 = min(index[r0c + 1], big)
            let t0 = bestTable(ix, 0, e0)
            if t0.bits >= best.bits { continue }
            for r1c in 0 ..< 8 {
                let e1 = min(index[min(r0c + r1c + 2, 22)], big)
                let t1 = bestTable(ix, e0, e1)
                let t2 = bestTable(ix, e1, big)
                let n = t0.bits + t1.bits + t2.bits
                if n < best.bits { best = (n, r0c, r1c, [t0.table, t1.table, t2.table]) }
                if e1 >= big { break }
            }
            if e0 >= big { break }
        }
        L.region0Count = best.r0
        L.region1Count = best.r1
        L.tableSelect = best.t
        L.bits = best.bits + count1Bits
        return L
    }

    /// Writes the big-values and count1 data of `ix` per `layout`.
    static func write(_ ix: [Int], _ L: Layout, blockType: Int, sampleRateIndex r: Int, to w: inout MSBBitWriter) {
        let big = L.bigValues * 2
        let ends: [Int]
        if blockType != 0 {
            ends = [min(big, implicitRegion0(blockType: blockType, sampleRateIndex: r)), big, big]
        } else {
            let index = MP3Decoder.bandIndexLong[r]
            ends = [min(index[L.region0Count + 1], big), min(index[min(L.region0Count + L.region1Count + 2, 22)], big), big]
        }
        var start = 0
        for region in 0 ..< 3 {
            let ts = L.tableSelect[region]
            let t = Int(MP3Tables.huffTable[ts]), lb = Int(MP3Tables.huffLinbits[ts])
            var i = start
            while i < ends[region] {
                if t > 0 {
                    let x = ix[i], y = ix[i + 1]
                    let ax = abs(x), ay = abs(y)
                    let ex = min(ax, 15), ey = min(ay, 15)
                    let s = ex << 4 | ey
                    w.write(codes[t][s], Int(lengths[t][s]))
                    if lb > 0 && ax >= 15 { w.write(ax - 15, lb) }
                    if ax != 0 { w.write(x < 0 ? 1 : 0, 1) }
                    if lb > 0 && ay >= 15 { w.write(ay - 15, lb) }
                    if ay != 0 { w.write(y < 0 ? 1 : 0, 1) }
                }
                i += 2
            }
            start = max(start, ends[region])
        }
        var q = big
        while q < L.count1End {
            let v = (abs(ix[q]) << 3) | (abs(ix[q + 1]) << 2) | (abs(ix[q + 2]) << 1) | abs(ix[q + 3])
            if L.count1Table == 0 { w.write(MP3Tables.quadCodes[0][v], Int(MP3Tables.quadBits[0][v])) } else { w.write(UInt32(15 - v), 4) }
            for k in 0 ..< 4 where ix[q + k] != 0 { w.write(ix[q + k] < 0 ? 1 : 0, 1) }
            q += 4
        }
    }
}

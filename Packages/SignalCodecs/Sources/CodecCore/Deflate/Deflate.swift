// RFC 1951 compressor: hash-chain LZ77 with lazy matching; each block is emitted
// as stored, fixed-Huffman or dynamic-Huffman, whichever is smallest. Dynamic codes
// are length-limited to 15 bits with the package-merge algorithm.

import Dispatch
import Synchronization

public enum Deflate {
    public struct Options: Sendable {
        public var maxChain = 128
        public var lazyThreshold = 32   // stop lazy evaluation once a match is this long
        public var blockSymbols = 1 << 16
        public init() {}
    }

    enum Symbol { case literal(UInt8), match(length: Int, distance: Int) }

    /// Inputs this large are compressed in parallel chunks (pigz style): each chunk's matcher
    /// starts with the 32 KiB before it, its matches end inside it, and it ends with an empty
    /// stored block (a sync flush), so the chunks' bytes concatenate into one stream.
    static let parallelChunk = 256 * 1024

    public static func compress(_ data: [UInt8], options: Options = Options()) -> [UInt8] {
        let chunks = (data.count + parallelChunk - 1) / parallelChunk
        guard chunks > 2 else { return compressRange(data, 0, data.count, final: true, options: options) }
        let results = Mutex<[[UInt8]]>(Array(repeating: [], count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { k in
            let lo = k * parallelChunk, hi = min(data.count, lo + parallelChunk)
            let part = compressRange(data, lo, hi, final: k == chunks - 1, options: options)
            results.withLock { $0[k] = part }
        }
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        for part in results.withLock({ $0 }) { out += part }
        return out
    }

    /// Deflate blocks for data[start..<end] (the bytes before `start`, up to the window, are
    /// matchable history); final: the last block is marked final, else a sync flush follows.
    static func compressRange(_ data: [UInt8], _ start: Int, _ end: Int, final isFinal: Bool, options: Options) -> [UInt8] {
        var w = LSBBitWriter(capacity: (end - start) / 2 + 64)
        var symbols: [Symbol] = []
        symbols.reserveCapacity(min(options.blockSymbols, end - start))
        var blockStart = start

        func flush(final: Bool, upTo blockEnd: Int) {
            writeBlock(&w, symbols, raw: data[blockStart..<blockEnd], final: final)
            symbols.removeAll(keepingCapacity: true)
            blockStart = blockEnd
        }

        if end <= start {
            writeBlock(&w, [], raw: data[start..<start], final: isFinal)
            if !isFinal { syncFlush(&w) }
            return w.finish()
        }

        let window = 32_768, hashBits = 15
        var head = [Int32](repeating: -1, count: 1 << hashBits)
        var prev = [Int32](repeating: -1, count: window)
        @inline(__always) func hash(_ i: Int) -> Int {
            (Int(data[i]) << 10 ^ Int(data[i + 1]) << 5 ^ Int(data[i + 2])) & ((1 << hashBits) - 1)
        }
        func insert(_ i: Int) {
            guard i + 2 < data.count else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = Int32(i)
        }
        func longestMatch(_ i: Int) -> (Int, Int) {
            guard i + 2 < end else { return (0, 0) }
            var best = 0, bestDist = 0
            var cand = Int(head[hash(i)])
            var chain = options.maxChain
            let maxLen = min(258, end - i)
            while cand >= 0 && i - cand <= window && chain > 0 {
                if data[cand + best] == data[i + best] || best == 0 {
                    var l = 0
                    while l < maxLen && data[cand + l] == data[i + l] { l += 1 }
                    if l > best {
                        best = l
                        bestDist = i - cand
                        if l == maxLen { break }
                    }
                }
                let p = Int(prev[cand & (window - 1)])
                if p >= cand { break }
                cand = p
                chain -= 1
            }
            return best >= 3 ? (best, bestDist) : (0, 0)
        }

        // The history before the chunk.
        var h = max(0, start - window)
        while h < start { insert(h); h += 1 }
        var i = start
        while i < end {
            var (len, dist) = longestMatch(i)
            if len > 0 && len < options.lazyThreshold && i + 1 < end {
                insert(i)
                let (len2, dist2) = longestMatch(i + 1)
                if len2 > len {
                    symbols.append(.literal(data[i]))
                    i += 1
                    (len, dist) = (len2, dist2)
                } else {
                    // Already inserted position i.
                    symbols.append(.match(length: len, distance: dist))
                    for k in 1..<len { insert(i + k) }
                    i += len
                    if symbols.count >= options.blockSymbols { flush(final: false, upTo: i) }
                    continue
                }
            }
            if len > 0 {
                symbols.append(.match(length: len, distance: dist))
                for k in 0..<len { insert(i + k) }
                i += len
            } else {
                symbols.append(.literal(data[i]))
                insert(i)
                i += 1
            }
            if symbols.count >= options.blockSymbols { flush(final: false, upTo: i) }
        }
        flush(final: isFinal, upTo: end)
        if !isFinal { syncFlush(&w) }
        return w.finish()
    }

    /// An empty stored block: the stream continues at a byte boundary.
    static func syncFlush(_ w: inout LSBBitWriter) {
        w.write(0, 1)
        w.write(0, 2)
        w.alignToByte()
        w.write(0, 16)
        w.write(0xFFFF, 16)
    }

    /// Length (3 … 258) → index into Inflate.lengthBase; distance − 1 → index into distBase
    /// (via distance − 1 for d ≤ 256, else 256 + (d − 1) >> 7; zlib's _dist_code).
    static let lengthIndex: [UInt8] = (0...258).map { len in
        var c = 28
        while len >= 3 && Inflate.lengthBase[c] > len { c -= 1 }
        return UInt8(c)
    }
    static let distIndex: [UInt8] = (0..<512).map { k in
        let d = k < 256 ? k + 1 : ((k - 256) << 7) + 1
        var c = 29
        while Inflate.distBase[c] > d { c -= 1 }
        return UInt8(c)
    }

    // MARK: block encoding

    @inline(__always) static func lengthCode(_ len: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let c = Int(lengthIndex[len])
        return (257 + c, Inflate.lengthExtra[c], len - Inflate.lengthBase[c])
    }

    @inline(__always) static func distCode(_ d: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let c = Int(distIndex[d <= 256 ? d - 1 : 256 + ((d - 1) >> 7)])
        return (c, Inflate.distExtra[c], d - Inflate.distBase[c])
    }

    static func writeBlock(_ w: inout LSBBitWriter, _ symbols: [Symbol], raw: ArraySlice<UInt8>, final: Bool) {
        var litFreq = [Int](repeating: 0, count: 286), distFreq = [Int](repeating: 0, count: 30)
        var extraBits = 0
        for s in symbols {
            switch s {
            case .literal(let b): litFreq[Int(b)] += 1
            case .match(let l, let d):
                let lc = lengthCode(l), dc = distCode(d)
                litFreq[lc.code] += 1
                distFreq[dc.code] += 1
                extraBits += lc.extraBits + dc.extraBits
            }
        }
        litFreq[256] += 1

        // Dynamic code.
        let litLens = Huffman.lengths(litFreq, maxBits: 15)
        var distLens = Huffman.lengths(distFreq, maxBits: 15)
        if distLens.allSatisfy({ $0 == 0 }) { distLens[0] = 1 }  // at least one distance code
        let header = DynamicHeader(litLens: litLens, distLens: distLens)
        func cost(_ lit: [UInt8], _ dist: [UInt8]) -> Int {
            var bits = extraBits
            for (i, f) in litFreq.enumerated() { bits += f * Int(lit[i]) }
            for (i, f) in distFreq.enumerated() { bits += f * Int(dist[i]) }
            return bits
        }
        let dynamicBits = 3 + header.bits + cost(litLens, distLens)
        let fixedBits = 3 + cost(Huffman.fixedLit, Huffman.fixedDist)
        let storedBits = raw.isEmpty ? 3 + 8 + 32 : ((raw.count + 65_534) / 65_535) * (3 + 8 + 32) + raw.count * 8 + 7

        if storedBits < min(dynamicBits, fixedBits) {
            var off = raw.startIndex
            repeat {
                let n = min(65_535, raw.endIndex - off)
                let last = final && off + n == raw.endIndex
                w.write(last ? 1 : 0, 1)
                w.write(0, 2)
                w.alignToByte()
                w.write(UInt32(n), 16)
                w.write(UInt32(~n & 0xFFFF), 16)
                w.appendAligned(raw[off..<(off + n)])
                off += n
            } while off < raw.endIndex
            return
        }

        w.write(final ? 1 : 0, 1)
        let lit: [UInt8], dist: [UInt8]
        if fixedBits <= dynamicBits {
            w.write(1, 2)
            (lit, dist) = (Huffman.fixedLit, Huffman.fixedDist)
        } else {
            w.write(2, 2)
            header.write(&w)
            (lit, dist) = (litLens, distLens)
        }
        let litCodes = Huffman.codes(lit), distCodes = Huffman.codes(dist)
        for s in symbols {
            switch s {
            case .literal(let b):
                w.write(litCodes[Int(b)], Int(lit[Int(b)]))
            case .match(let l, let d):
                let lc = lengthCode(l), dc = distCode(d)
                w.write(litCodes[lc.code], Int(lit[lc.code]))
                if lc.extraBits > 0 { w.write(UInt32(lc.extra), lc.extraBits) }
                w.write(distCodes[dc.code], Int(dist[dc.code]))
                if dc.extraBits > 0 { w.write(UInt32(dc.extra), dc.extraBits) }
            }
        }
        w.write(litCodes[256], Int(lit[256]))
    }

    struct DynamicHeader {
        var hlit = 0, hdist = 0, hclen = 0
        var clLens: [UInt8] = []
        var rle: [(sym: Int, extra: Int)] = []
        var bits = 0

        init(litLens: [UInt8], distLens: [UInt8]) {
            hlit = max(257, (litLens.lastIndex { $0 != 0 } ?? 0) + 1)
            hdist = max(1, (distLens.lastIndex { $0 != 0 } ?? 0) + 1)
            let all = Array(litLens[0..<hlit]) + Array(distLens[0..<hdist])
            // RLE with 16 (repeat previous 3-6), 17 (zeros 3-10), 18 (zeros 11-138).
            var i = 0
            while i < all.count {
                let v = all[i]
                var run = 1
                while i + run < all.count && all[i + run] == v { run += 1 }
                if v == 0 && run >= 3 {
                    var r = run
                    while r >= 3 {
                        if r >= 11 { let n = min(r, 138); rle.append((18, n - 11)); r -= n }
                        else { let n = min(r, 10); rle.append((17, n - 3)); r -= n }
                    }
                    for _ in 0..<r { rle.append((0, 0)) }
                } else if v != 0 && run >= 4 {
                    rle.append((Int(v), 0))
                    var r = run - 1
                    while r >= 3 { let n = min(r, 6); rle.append((16, n - 3)); r -= n }
                    for _ in 0..<r { rle.append((Int(v), 0)) }
                } else {
                    for _ in 0..<run { rle.append((Int(v), 0)) }
                }
                i += run
            }
            var clFreq = [Int](repeating: 0, count: 19)
            for e in rle { clFreq[e.sym] += 1 }
            // The code-length code must be complete (zlib rejects a lone 1-bit code here).
            if clFreq.filter({ $0 > 0 }).count == 1 { clFreq[clFreq[0] > 0 ? 1 : 0] = 1 }
            clLens = Huffman.lengths(clFreq, maxBits: 7)
            hclen = 4
            for (k, sym) in DeflateGrammar.codeLengthOrder.enumerated() where clLens[sym] != 0 { hclen = max(hclen, k + 1) }
            bits = 5 + 5 + 4 + 3 * hclen
            for e in rle {
                bits += Int(clLens[e.sym]) + (e.sym == 16 ? 2 : e.sym == 17 ? 3 : e.sym == 18 ? 7 : 0)
            }
        }

        func write(_ w: inout LSBBitWriter) {
            w.write(UInt32(hlit - 257), 5)
            w.write(UInt32(hdist - 1), 5)
            w.write(UInt32(hclen - 4), 4)
            for k in 0..<hclen { w.write(UInt32(clLens[DeflateGrammar.codeLengthOrder[k]]), 3) }
            let codes = Huffman.codes(clLens)
            for e in rle {
                w.write(codes[e.sym], Int(clLens[e.sym]))
                switch e.sym {
                case 16: w.write(UInt32(e.extra), 2)
                case 17: w.write(UInt32(e.extra), 3)
                case 18: w.write(UInt32(e.extra), 7)
                default: break
                }
            }
        }
    }

    enum Huffman {
        static let fixedLit: [UInt8] = (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 }
        static let fixedDist: [UInt8] = [UInt8](repeating: 5, count: 30)

        /// Canonical codes, bit-reversed for LSB-first output.
        static func codes(_ lens: [UInt8]) -> [UInt32] {
            var count = [Int](repeating: 0, count: 16)
            for l in lens where l > 0 { count[Int(l)] += 1 }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for b in 1..<16 { code = (code + count[b - 1]) << 1; next[b] = code }
            return lens.map { l in
                guard l > 0 else { return 0 }
                let c = next[Int(l)]
                next[Int(l)] += 1
                var r: UInt32 = 0
                for k in 0..<Int(l) where c & (1 << k) != 0 { r |= 1 << UInt32(Int(l) - 1 - k) }
                return r
            }
        }

        /// Length-limited Huffman code lengths (package-merge). A single used
        /// symbol gets length 1; unused symbols get 0.
        static func lengths(_ freq: [Int], maxBits: Int) -> [UInt8] {
            let used = freq.indices.filter { freq[$0] > 0 }
            var lens = [UInt8](repeating: 0, count: freq.count)
            if used.isEmpty { return lens }
            if used.count == 1 { lens[used[0]] = 1; return lens }
            // Each item: (weight, symbols it contains).
            let leaves = used.sorted { (freq[$0], $0) < (freq[$1], $1) }.map { (freq[$0], [$0]) }
            var current = leaves
            for _ in 1..<maxBits {
                var packaged: [(Int, [Int])] = []
                var k = 0
                while k + 1 < current.count {
                    packaged.append((current[k].0 + current[k + 1].0, current[k].1 + current[k + 1].1))
                    k += 2
                }
                // Merge leaves and packages by weight.
                var merged: [(Int, [Int])] = []
                merged.reserveCapacity(leaves.count + packaged.count)
                var a = 0, b = 0
                while a < leaves.count || b < packaged.count {
                    if b >= packaged.count || (a < leaves.count && leaves[a].0 <= packaged[b].0) { merged.append(leaves[a]); a += 1 }
                    else { merged.append(packaged[b]); b += 1 }
                }
                current = merged
            }
            for item in current.prefix(2 * used.count - 2) { for s in item.1 { lens[s] += 1 } }
            return lens
        }
    }
}

public enum ZlibWriter {
    /// zlib container (CMF 0x78, FLG for default level) around a Deflate stream.
    public static func compress(_ data: [UInt8], options: Deflate.Options = Deflate.Options()) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        out += Deflate.compress(data, options: options)
        let a = Adler32.checksum(data)
        out += [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
        return out
    }
}

/// Huffman code construction shared by the encoders (Deflate, VP8L).
public enum HuffmanCodeBuilder {
    /// Length-limited code lengths (package-merge); one used symbol gets length 1.
    public static func lengths(_ freq: [Int], maxBits: Int) -> [UInt8] { Deflate.Huffman.lengths(freq, maxBits: maxBits) }
    /// Canonical codes, bit-reversed for LSB-first writers.
    public static func codes(_ lengths: [UInt8]) -> [UInt32] { Deflate.Huffman.codes(lengths) }
}

public struct VP9Frame: Sendable {
    public let width, height, yStride, uvStride: Int
    public let y, u, v: [UInt8]
    fileprivate init(_ picture: VP9Picture) {
        (width,height,yStride,uvStride) = (picture.planes[0].width,picture.planes[0].height,picture.planes[0].stride,picture.planes[1].stride)
        (y,u,v) = (picture.planes[0].bytes,picture.planes[1].bytes,picture.planes[2].bytes)
    }
}

/// RingRTC group video uses profile-0 VP9. One decoder owns one sender's eight
/// reference slots, including inter-layer references in a scalable stream.
public struct VP9VideoDecoder {
    private var refs = [VP9Picture?](repeating:nil,count:8)
    private var previous: VP9Picture?
    private var previousShown = false, previousIntra = true, previousKey = false
    private var segmentation = VP9Segmentation()
    private var contexts = [[Int]](repeating:VP9Prob.initial,count:4)
    private var refDelta = [1,0,-1,-1], modeDelta = [0,0]

    public init() {}

    public mutating func decode(_ bytes: [UInt8]) throws -> VP9Frame? {
        guard (1...(8 << 20)).contains(bytes.count) else { throw VP9DecodeError.malformed }
        // A superframe's size index is optional. Parse each coded subframe in
        // order and present only the last displayable one.
        var slices: [Range<Int>] = []
        if let marker = bytes.last, marker & 224 == 192 {
            let count = Int(marker & 7)+1, sizeBytes = Int((marker >> 3) & 3)+1
            let index = bytes.count-(2+count*sizeBytes)
            if index >= 0, bytes[index] == marker {
                var pos = index+1, next = 0
                for _ in 0..<count {
                    var size = 0
                    for i in 0..<sizeBytes { size |= Int(bytes[pos]) << (8*i); pos += 1 }
                    guard size > 0, size <= index-next else { throw VP9DecodeError.malformed }
                    slices.append(next..<(next+size))
                    next += size
                }
                guard next == index else { throw VP9DecodeError.malformed }
            }
        }
        if slices.isEmpty { slices = [bytes.indices] }
        var work = self, shown: VP9Picture?
        for range in slices {
            if let display = try work.picture(range == bytes.indices ? bytes : Array(bytes[range])) { shown = display }
        }
        self = work
        return shown.map(VP9Frame.init)
    }

    private mutating func picture(_ bytes: [UInt8]) throws -> VP9Picture? {
        var h = try VP9Header(bytes,sizes:refs.map { $0.map { ($0.planes[0].width,$0.planes[0].height) } },segmentation:segmentation)
        if let slot = h.existing {
            guard let picture = refs[slot] else { throw VP9DecodeError.missingReference }
            return picture
        }
        guard h.intra || previous != nil else { throw VP9DecodeError.missingReference }
        if h.intra || h.resilient {
            if h.key || h.resilient || h.reset == 3 { contexts = .init(repeating:VP9Prob.initial,count:4) }
            else if h.reset == 2 { contexts[h.context] = VP9Prob.initial }
            h.context = 0
            refDelta = [1,0,-1,-1]; modeDelta = [0,0]
        }
        let p = VP9Picture(width:h.width,height:h.height)
        for i in refDelta.indices { if let v = h.refDeltas[i] { refDelta[i] = v } }
        for i in modeDelta.indices { if let v = h.modeDeltas[i] { modeDelta[i] = v } }
        let entropy = VP9Context(contexts[h.context])
        var pos = h.headerBytes+h.compressedBytes
        try entropy.decodeHeader(bytes[h.headerBytes..<pos],header:h)
        let columns = 1 << h.logCols, rows = 1 << h.logRows
        func start(_ n: Int, _ count: Int, _ log: Int) -> Int { min(count,(((count+7)/8*n) >> log)*8) }
        let sameSize = previous.map { $0.planes[0].width == h.width && $0.planes[0].height == h.height } == true
        let temporal = !h.resilient && !previousIntra && previousShown && sameSize
        var upperContexts: [(partition: [Int], nonzero: [[Int]])?] = .init(repeating:nil,count:columns)
        for tr in 0..<rows { for tc in 0..<columns {
            var length = bytes.count-pos
            if tr*columns+tc < columns*rows-1 {
                guard length >= 4 else { throw VP9DecodeError.malformed }
                length = 0
                for _ in 0..<4 { length = length*256+Int(bytes[pos]); pos += 1 }
            }
            guard length > 0, length <= bytes.count-pos else { throw VP9DecodeError.malformed }
            let area = (start(tc,p.cols,h.logCols),start(tc+1,p.cols,h.logCols),start(tr,p.rows,h.logRows),start(tr+1,p.rows,h.logRows))
            let tile = try VP9Tile(bytes[pos..<(pos+length)],h:h,context:entropy,picture:p,references:refs,
                                 previous:previous,usePreviousMVs:temporal,area:area,refDelta:refDelta,modeDelta:modeDelta)
            if let upper = upperContexts[tc] { tile.partAbove = upper.partition; tile.nzAbove = upper.nonzero }
            try tile.decode()
            upperContexts[tc] = (tile.partAbove,tile.nzAbove)
            pos += length
        } }
        if h.level > 0 {
            for index in 0..<3 {
                let shift = index == 0 ? 0 : 1
                p.planes[index].filter(sharpness:h.sharpness,chroma:index != 0) { row4,col4 in
                    let x = (col4*4) << shift, y = (row4*4) << shift
                    let cellX = index == 0 ? x/8 : col4 & ~1
                    let cellY = index == 0 ? y/8 : row4 & ~1
                    let block = p.blocks[min(p.rows-1,cellY)*p.cols+min(p.cols-1,cellX)]
                    let width = max(8,block.width), height = max(8,block.height)
                    let maxTx = min(width,height).trailingZeroBitCount-shift-2
                    return VP9FilterBlock(level:block.level,tx:min(block.tx,maxTx),skip:block.skip && block.refs.0 != 0,
                                          left:x == block.originX,top:y == block.originY)
                }
            }
        }
        if h.saveContext {
            if !h.resilient && !h.parallel { entropy.adapt(from:contexts[h.context],intra:h.intra,afterKey:previousKey) }
            contexts[h.context] = entropy.probabilities
        }
        for i in refs.indices where h.refresh & (1 << i) != 0 { refs[i] = p }
        previous = p; previousIntra = h.intra; previousShown = h.show; previousKey = h.key
        segmentation = h.segmentation
        return h.show ? p : nil
    }
}

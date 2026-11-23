import Dispatch
import Synchronization

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
        for i in refDelta.indices { if let v = h.refDeltas[i] { refDelta[i] = v } }
        for i in modeDelta.indices { if let v = h.modeDeltas[i] { modeDelta[i] = v } }
        var entropy = VP9Context(contexts[h.context])
        var pos = h.headerBytes+h.compressedBytes
        try entropy.decodeHeader(bytes[h.headerBytes..<pos],header:h)
        let cols = (h.width+7)/8, rows = (h.height+7)/8
        let tileCols = 1 << h.logCols, tileRows = 1 << h.logRows
        @Sendable func start(_ n: Int, _ count: Int, _ log: Int) -> Int { min(count,(((count+7)/8*n) >> log)*8) }
        let sameSize = previous.map { $0.planes[0].width == h.width && $0.planes[0].height == h.height } == true
        let temporal = !h.resilient && !previousIntra && previousShown && sameSize
        // Every tile's bytes, in bitstream order (row by row), filed by column.
        var tiles = [[Range<Int>]](repeating: [], count: tileCols)
        for tr in 0..<tileRows { for tc in 0..<tileCols {
            var length = bytes.count-pos
            if tr*tileCols+tc < tileCols*tileRows-1 {
                guard length >= 4 else { throw VP9DecodeError.malformed }
                length = 0
                for _ in 0..<4 { length = length*256+Int(bytes[pos]); pos += 1 }
            }
            guard length > 0, length <= bytes.count-pos else { throw VP9DecodeError.malformed }
            tiles[tc].append(pos..<(pos+length))
            pos += length
        } }
        let rowBounds = (0...tileRows).map { start($0,rows,h.logRows) }, tileBytes = tiles
        // What each column reads, captured by value (the columns may run on other threads).
        let header = h, shared = entropy, references = refs, prior = previous
        let frameRefDelta = refDelta, frameModeDelta = modeDelta
        @Sendable func column(_ tc: Int) throws -> VP9Tile {
            var tile = try VP9Tile(h:header,context:shared,references:references,previous:prior,usePreviousMVs:temporal,
                                   columns:start(tc,cols,header.logCols)..<start(tc+1,cols,header.logCols),
                                   refDelta:frameRefDelta,modeDelta:frameModeDelta,firstTile:bytes[tileBytes[tc][0]],rows:rowBounds[0]..<rowBounds[1])
            try tile.decode()
            for tr in 1..<tileRows {
                try tile.next(bytes[tileBytes[tc][tr]],rows:rowBounds[tr]..<rowBounds[tr+1])
                try tile.decode()
            }
            if header.level > 0 { tile.decideFilterEdges() }
            return tile
        }
        var planes: [VP9Plane], blocks: [VP9Block], filterCodes: [[Int32]] = []
        if tileCols == 1 {
            let tile = try column(0)
            (planes,blocks,filterCodes) = (tile.planes,tile.blocks,tile.filterCodes)
            entropy.add(tile.context)
        } else {
            // Tile columns share nothing while they decode: each on its own thread.
            let results = Mutex<[Result<VP9Tile,any Error>?]>(.init(repeating:nil,count:tileCols))
            DispatchQueue.concurrentPerform(iterations:tileCols) { tc in
                let result = Result { try column(tc) }
                results.withLock { $0[tc] = result }
            }
            var decoded: [VP9Tile] = []
            for result in results.withLock({ $0 }) {
                guard let result else { throw VP9DecodeError.malformed }
                decoded.append(try result.get())
            }
            planes = (0..<3).map { i in VP9Plane(strips: decoded.map { $0.planes[i] }) }
            blocks = []
            blocks.reserveCapacity(cols*rows)
            for y in 0..<rows {
                for tile in decoded {
                    let span = tile.right-tile.left
                    blocks.append(contentsOf: tile.blocks[(y*span)..<((y+1)*span)])
                }
            }
            for tile in decoded { entropy.add(tile.context) }
            if h.level > 0 {
                filterCodes = (0..<3).map { p in
                    var codes = [Int32]()
                    let unitRows = decoded[0].filterCodes[p].count / max(1,decoded[0].filterWidths[p])
                    for row in 0..<unitRows {
                        for tile in decoded {
                            let width = tile.filterWidths[p]
                            codes.append(contentsOf: tile.filterCodes[p][(row*width)..<((row+1)*width)])
                        }
                    }
                    return codes
                }
            }
        }
        if h.level > 0 {
            // The planes filter independently, each on its own thread. A plane moves into its job
            // (the slot keeps no reference), so it is filtered in place, not copied. (Superblock
            // rows as a wavefront, as libvpx does, gained ~2% wall time for ~50% more CPU here:
            // a row on an efficiency core holds back every row below it.)
            let slots = Mutex<[VP9Plane?]>(planes.map { $0 }), codes = filterCodes
            planes = []
            let sharpness = h.sharpness
            DispatchQueue.concurrentPerform(iterations:3) { index in
                guard var plane = slots.withLock({ $0[index].take() }) else { return }
                plane.filter(sharpness:sharpness,chroma:index != 0,codes:codes[index])
                slots.withLock { $0[index] = plane }
            }
            for plane in slots.withLock({ $0 }) {
                guard let plane else { throw VP9DecodeError.malformed }
                planes.append(plane)
            }
        }
        let p = VP9Picture(cols:cols,rows:rows,planes:planes,blocks:blocks)
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

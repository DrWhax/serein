// The decoding process around the slices (H.264 8.2): parameter set storage, picture
// boundaries, picture order count (8.2.1, types 0/1/2), reference picture marking (8.2.5:
// sliding window and MMCO 1–6), reference list construction and modification (8.2.4) for
// frames, and output in POC order with the stream's reorder delay (C.4.5.3 bumping).
//
// Errors in one slice or picture throw; a caller that wants to conceal can drop the access
// unit and continue (the next IDR resynchronises).

public import CodecCore


public struct H264Frame: Sendable {
    /// The display window (cropped), 8-bit I420.
    public var picture: YUVPicture
    public var poc: Int
    public var pts: Int64?
    public var fullRange: Bool
    public var matrixCoefficients: Int
}

public struct H264Decoder: Sendable {
    public struct Limits: Sendable {
        public var maxMacroblocks = 8192 * 4352 / 256     // ≈ 8K
        public var maxSlicesPerPicture = 1024
        /// Worker threads for reconstruction and deblocking.
        public var threads = 8
        public init() {}
    }

    var sps: [Int: H264SPS] = [:]
    var pps: [Int: H264PPS] = [:]
    let limits: Limits
    var active: H264SPS?
    var current: H264PictureDecoder?
    var currentHeader: H264SliceHeader?
    var currentPOC = (top: 0, bottom: 0, poc: 0, msb: 0)
    var currentPTS: Int64?
    var sliceCount: Int32 = 0
    var dpb: [DecodedPicture] = []
    var decodeIndex = 0
    var epoch = 0
    // POC state.
    var prevRefPocMsb = 0, prevRefPocLsb = 0
    var prevFrameNumOffset = 0, prevFrameNum = 0
    var prevRefHadMMCO5 = false
    var output: [H264Frame] = []
    /// NAL units or slices that could not be decoded (their macroblocks were concealed).
    public private(set) var errorCount = 0
    public private(set) var lastError: ParseFailure?

    public init(limits: Limits = Limits()) { self.limits = limits }

    /// From an MP4 avcC record's parameter sets.
    public init(sequenceParameterSets: [[UInt8]], pictureParameterSets: [[UInt8]], limits: Limits = Limits()) throws(ParseFailure) {
        self.limits = limits
        for s in sequenceParameterSets { try addNAL(try NALUnit.make(s[...])) }
        for p in pictureParameterSets { try addNAL(try NALUnit.make(p[...])) }
    }

    mutating func addNAL(_ nal: NALUnit) throws(ParseFailure) {
        switch nal.type {
        case NALUnit.sps:
            let s = try H264SPS.parse(nal.rbsp)
            guard s.widthMbs * s.heightMbs <= limits.maxMacroblocks else { throw ParseFailure(offset: 0, rule: "sps", reason: .limitExceeded("picture too large")) }
            sps[s.id] = s
        case NALUnit.pps:
            let p = try H264PPS.parse(nal.rbsp, sps: { sps[$0] })
            pps[p.id] = p
        default:
            break
        }
    }

    /// Decodes one access unit (an MP4 sample); returns the frames that became ready for
    /// display (in display order).
    /// Damaged data does not stop decoding: what cannot be decoded is concealed (copied from
    /// the last reference picture, or grey) and counted in `errorCount`.
    public mutating func decode(sample: ByteSlice, nalLengthSize: Int, pts: Int64? = nil) -> [H264Frame] {
        let (units, damaged) = NALUnit.unitsLenient(sample: sample, lengthSize: nalLengthSize)
        if damaged { record(ParseFailure(offset: 0, rule: "nal_unit", reason: .invalid("damaged NAL length"))) }
        for u in units { decodeNALResilient(u, pts: pts) }
        finishPicture()
        let out = output
        output = []
        return out
    }

    /// Decodes an Annex B byte stream.
    public mutating func decode(annexB bytes: [UInt8]) -> [H264Frame] {
        do {
            for u in try NALUnit.units(annexB: bytes) { decodeNALResilient(u, pts: nil) }
        } catch {
            record(error)
        }
        finishPicture()
        let out = output
        output = []
        return out
    }

    mutating func record(_ e: ParseFailure) {
        errorCount += 1
        lastError = e
    }

    mutating func decodeNALResilient(_ nal: NALUnit, pts: Int64?) {
        do { try decodeNAL(nal, pts: pts) } catch { record(error) }
    }

    /// The pictures still held for reordering.
    public mutating func flush() -> [H264Frame] {
        finishPicture()
        while bump() {}
        let out = output
        output = []
        return out
    }

    mutating func decodeNAL(_ nal: NALUnit, pts: Int64?) throws(ParseFailure) {
        switch nal.type {
        case NALUnit.slice, NALUnit.sliceIDR:
            let (h, reader, s, p) = try H264SliceHeader.parse(nal, sps: { sps[$0] }, pps: { pps[$0] })
            var r = reader
            if h.firstMb == 0 || current == nil || currentHeader?.frameNum != h.frameNum || active?.id != s.id {
                // A new picture (when its first slice was lost, the missing part is concealed).
                finishPicture()
                try startPicture(h, s, p, pts: pts)
            }
            sliceCount += 1
            guard sliceCount <= Int32(limits.maxSlicesPerPicture) else { throw ParseFailure(offset: 0, rule: "slice", reason: .limitExceeded("too many slices")) }
            let refs = SliceRefs(lists: try referenceLists(h, s), currentPOC: currentPOC.poc)
            let dq = current!.dequantCache[p.id] ?? current!.dequant(p)
            current!.dequantCache[p.id] = dq
            current!.slices.append(SliceInfo(header: h, pps: p, refs: refs, dequant: dq,
                                             deblock: SliceDeblock(disable: h.disableDeblocking, alpha: h.alphaOffset, beta: h.betaOffset)))
            if p.cabac {
                try current!.decodeSliceCABAC(h, p, r, rbsp: nal.rbsp, slice: sliceCount - 1, refs: refs)
            } else {
                try current!.decodeSliceCAVLC(h, p, &r, slice: sliceCount - 1, refs: refs)
            }
        case NALUnit.sps, NALUnit.pps:
            finishPicture()
            try addNAL(nal)
        case NALUnit.aud, NALUnit.endOfSequence, NALUnit.endOfStream:
            finishPicture()
        default:
            break   // SEI, filler, extensions: ignored
        }
    }

    // MARK: pictures

    mutating func startPicture(_ h: H264SliceHeader, _ s: H264SPS, _ p: H264PPS, pts: Int64?) throws(ParseFailure) {
        if active != s {
            // A new sequence: what is pending is output first.
            while bump() {}
            dpb = []
            active = s
        }
        if h.idr {
            if !h.noOutputOfPriorPics { while bump() {} }
            dpb = []
            epoch += 1
        }
        currentHeader = h
        currentPTS = pts
        currentPOC = computePOC(h, s)
        current = H264PictureDecoder(sps: s)
        sliceCount = 0
    }

    mutating func finishPicture() {
        guard var pd = current, let h = currentHeader, let s = active else { return }
        current = nil
        currentHeader = nil
        if pd.st.slice.contains(where: { $0 < 0 }) {
            conceal(&pd)
        }
        let picture = pd.reconstructPicture(threads: limits.threads)
        // References keep only what later pictures read.
        pd.slices = []
        var dp = DecodedPicture(picture: picture, motion: pd.st.motion, poc: currentPOC.poc, frameNum: h.frameNum, decodeIndex: decodeIndex, epoch: epoch, pts: currentPTS)
        decodeIndex += 1
        let hadMMCO5 = h.mmco.contains { $0.op == 5 }
        if h.nalRefIdc != 0 {
            markReferences(h, s, &dp)
            prevRefPocMsb = hadMMCO5 ? 0 : currentPOC.msb
            prevRefPocLsb = hadMMCO5 ? currentPOC.top - min(currentPOC.top, currentPOC.bottom) : h.pocLsb
            if hadMMCO5 {
                dp.poc = 0
                dp.frameNum = 0
            }
        }
        prevRefHadMMCO5 = hadMMCO5
        prevFrameNumOffset = hadMMCO5 ? 0 : frameNumOffset(h, s)
        prevFrameNum = hadMMCO5 ? 0 : h.frameNum
        // Store, then output while more pictures wait than the stream reorders.
        dpb.append(dp)
        let reorder = s.maxNumReorderFrames ?? dpbSize(s)
        while dpb.filter(\.neededForOutput).count > reorder { if !bump() { break } }
        // Keep the buffer bounded: unreferenced, output pictures leave.
        dpb.removeAll { !$0.isReference && !$0.neededForOutput }
        while dpb.count > dpbSize(s) + 1 { if !bump() { break }; dpb.removeAll { !$0.isReference && !$0.neededForOutput } }
    }

    /// Fills macroblocks no slice decoded: zero-motion copies of the most recent reference
    /// picture, or mid-grey without one; they are not deblocked.
    func conceal(_ pd: inout H264PictureDecoder) {
        let last = dpb.filter(\.isReference).max { $0.decodeIndex < $1.decodeIndex }.map(refPicture)
        let pps = pd.slices.first?.pps ?? self.pps.values.first ?? H264PPS()
        var header = H264SliceHeader()
        header.type = last != nil ? .p : .i
        let info = SliceInfo(header: header, pps: pps, refs: SliceRefs(lists: [last.map { [$0] } ?? [], []], currentPOC: currentPOC.poc),
                             dequant: pd.dequant(pps), deblock: SliceDeblock(disable: 1, alpha: 0, beta: 0))
        pd.slices.append(info)
        let slice = Int32(pd.slices.count - 1)
        for mb in 0 ..< pd.st.mbs where pd.st.slice[mb] < 0 {
            pd.beginMacroblock(mb)
            pd.st.slice[mb] = slice
            pd.st.cbp[mb] = 0
            pd.setQP(mb, 26, pps)
            if let ref = last {
                pd.st.kind[mb] = [.inter, .skip, .decoded]
                pd.st.motion.intra[mb] = false
                pd.setMotion(mb, x: 0, y: 0, w: 16, h: 16, list: 0, refIdx: 0, mvx: 0, mvy: 0, ref: ref)
                pd.addPart(mb, x: 0, y: 0, w: 16, h: 16)
            } else {
                pd.st.kind[mb] = [.pcm, .decoded]
                pd.st.motion.intra[mb] = true
                let base = mb * MBState.levelStride
                for i in 0 ..< 384 { pd.st.levels[base + i] = 128 }
            }
        }
    }

    func dpbSize(_ s: H264SPS) -> Int {
        if let n = s.maxDecFrameBuffering { return max(1, n) }
        // MaxDpbMbs by level (Table A-1).
        let table: [Int: Int] = [9: 396, 10: 396, 11: 900, 12: 2376, 13: 2376, 20: 2376, 21: 4752, 22: 8100, 30: 8100, 31: 18000, 32: 20480,
                                 40: 32768, 41: 32768, 42: 34816, 50: 110_400, 51: 184_320, 52: 184_320, 60: 696_320, 61: 696_320, 62: 696_320]
        let maxDpbMbs = table[s.levelIdc] ?? 696_320
        return min(16, max(1, maxDpbMbs / (s.widthMbs * s.heightMbs)))
    }

    /// Outputs the smallest-POC picture waiting for output.
    @discardableResult
    mutating func bump() -> Bool {
        guard let i = dpb.indices.filter({ dpb[$0].neededForOutput }).min(by: {
            (dpb[$0].epoch, dpb[$0].poc, dpb[$0].decodeIndex) < (dpb[$1].epoch, dpb[$1].poc, dpb[$1].decodeIndex)
        }) else { return false }
        dpb[i].neededForOutput = false
        if let s = active {
            let c = s.crop
            let pic = dpb[i].picture.cropped(left: 2 * c.left, top: 2 * c.top, width: s.width, height: s.height)
            output.append(H264Frame(picture: pic, poc: dpb[i].poc, pts: dpb[i].pts, fullRange: s.videoFullRange, matrixCoefficients: s.matrixCoefficients))
        }
        if !dpb[i].isReference { dpb.remove(at: i) }
        return true
    }

    // MARK: reference lists (8.2.4)

    func refPicture(_ p: DecodedPicture) -> RefPicture {
        RefPicture(picture: p.picture, motion: p.motion, poc: p.poc, longTerm: p.longTerm, id: Int32(truncatingIfNeeded: p.decodeIndex))
    }

    /// RefPicList0/1 for the slice: initialised (8.2.4.2) and modified (8.2.4.3).
    func referenceLists(_ h: H264SliceHeader, _ s: H264SPS) throws(ParseFailure) -> [[RefPicture?]] {
        guard h.type != .i else { return [[], []] }
        let maxFrameNum = 1 << s.log2MaxFrameNum
        let short = dpb.filter(\.shortTerm), long = dpb.filter(\.longTerm).sorted { $0.longTermFrameIdx < $1.longTermFrameIdx }
        var init0: [DecodedPicture], init1: [DecodedPicture] = []
        if h.type == .p {
            init0 = short.sorted { frameNumWrap($0, h.frameNum, maxFrameNum) > frameNumWrap($1, h.frameNum, maxFrameNum) } + long
        } else {
            let poc = currentPOC.poc
            let before = short.filter { $0.poc < poc }.sorted { $0.poc > $1.poc }, after = short.filter { $0.poc > poc }.sorted { $0.poc < $1.poc }
            init0 = before + after + long
            init1 = after + before + long
            if init1.count > 1 && init1.map(\.decodeIndex) == init0.map(\.decodeIndex) { init1.swapAt(0, 1) }
        }
        var lists: [[DecodedPicture?]] = [init0, init1]
        for l in 0 ..< (h.type == .b ? 2 : 1) {
            let n = l == 0 ? h.numRefIdxActive.l0 : h.numRefIdxActive.l1
            var list: [DecodedPicture?] = Array(lists[l].prefix(n))
            while list.count < n + 1 { list.append(nil) }
            var predPicNum = h.frameNum
            var refIdx = 0
            for (idc, value) in h.refModifications[l] {
                var pick: DecodedPicture?
                if idc < 2 {
                    let diff = value + 1
                    var noWrap = idc == 0 ? predPicNum - diff : predPicNum + diff
                    if noWrap < 0 { noWrap += maxFrameNum }
                    if noWrap >= maxFrameNum { noWrap -= maxFrameNum }
                    predPicNum = noWrap
                    let picNum = noWrap > h.frameNum ? noWrap - maxFrameNum : noWrap
                    pick = short.first { frameNumWrap($0, h.frameNum, maxFrameNum) == picNum }
                } else {
                    pick = long.first { $0.longTermFrameIdx == value }
                }
                guard let pick, refIdx <= n else { throw ParseFailure(offset: 0, rule: "ref_pic_list_modification", reason: .invalid("unknown picture")) }
                list.insert(pick, at: refIdx)
                refIdx += 1
                var k = refIdx
                for c in refIdx ..< list.count where list[c].map({ $0.decodeIndex != pick.decodeIndex }) ?? true {
                    list[k] = list[c]
                    k += 1
                }
                list = Array(list.prefix(n + 1))
            }
            lists[l] = Array(list.prefix(n))
        }
        return lists.map { $0.map { $0.map(refPicture) } }
    }

    // MARK: POC (8.2.1)

    func frameNumOffset(_ h: H264SliceHeader, _ s: H264SPS) -> Int {
        if h.idr { return 0 }
        let prevOffset = prevRefHadMMCO5 ? 0 : prevFrameNumOffset
        return prevFrameNum > h.frameNum ? prevOffset + (1 << s.log2MaxFrameNum) : prevOffset
    }

    func computePOC(_ h: H264SliceHeader, _ s: H264SPS) -> (top: Int, bottom: Int, poc: Int, msb: Int) {
        switch s.pocType {
        case 0:
            let maxLsb = 1 << s.log2MaxPocLsb
            let prevMsb = h.idr ? 0 : prevRefPocMsb, prevLsb = h.idr ? 0 : prevRefPocLsb
            var msb = prevMsb
            if h.pocLsb < prevLsb && prevLsb - h.pocLsb >= maxLsb / 2 { msb = prevMsb + maxLsb }
            else if h.pocLsb > prevLsb && h.pocLsb - prevLsb > maxLsb / 2 { msb = prevMsb - maxLsb }
            let top = msb + h.pocLsb, bottom = top + h.deltaPocBottom
            return (top, bottom, min(top, bottom), msb)
        case 1:
            let offset = frameNumOffset(h, s)
            let cycle = s.offsetForRefFrame.count
            var absFrameNum = cycle != 0 ? offset + h.frameNum : 0
            if h.nalRefIdc == 0 && absFrameNum > 0 { absFrameNum -= 1 }
            var expected = 0
            if absFrameNum > 0 {
                let delta = s.offsetForRefFrame.reduce(0, +)
                let cycleCount = (absFrameNum - 1) / cycle, inCycle = (absFrameNum - 1) % cycle
                expected = cycleCount * delta
                for i in 0 ... inCycle { expected += s.offsetForRefFrame[i] }
            }
            if h.nalRefIdc == 0 { expected += s.offsetForNonRefPic }
            let top = expected + h.deltaPoc.0
            let bottom = top + s.offsetForTopToBottomField + h.deltaPoc.1
            return (top, bottom, min(top, bottom), 0)
        default:
            let offset = frameNumOffset(h, s)
            let t = h.idr ? 0 : (h.nalRefIdc == 0 ? 2 * (offset + h.frameNum) - 1 : 2 * (offset + h.frameNum))
            return (t, t, t, 0)
        }
    }

    // MARK: reference marking (8.2.5)

    mutating func markReferences(_ h: H264SliceHeader, _ s: H264SPS, _ cur: inout DecodedPicture) {
        let maxFrameNum = 1 << s.log2MaxFrameNum
        if h.idr {
            for i in dpb.indices { dpb[i].shortTerm = false; dpb[i].longTermFrameIdx = -1 }
            if h.longTermReference { cur.longTermFrameIdx = 0 } else { cur.shortTerm = true }
            return
        }
        var currentMarked = false
        if h.adaptiveRefMarking {
            var maxLongTermIdx = 16
            for op in h.mmco {
                switch op.op {
                case 1:
                    let picNum = h.frameNum - (op.a + 1)
                    for i in dpb.indices where dpb[i].shortTerm && picNumOf(dpb[i], h.frameNum, maxFrameNum) == picNum { dpb[i].shortTerm = false }
                case 2:
                    for i in dpb.indices where dpb[i].longTermFrameIdx == op.a { dpb[i].longTermFrameIdx = -1 }
                case 3:
                    let picNum = h.frameNum - (op.a + 1)
                    for i in dpb.indices where dpb[i].longTermFrameIdx == op.b { dpb[i].longTermFrameIdx = -1 }
                    for i in dpb.indices where dpb[i].shortTerm && picNumOf(dpb[i], h.frameNum, maxFrameNum) == picNum {
                        dpb[i].shortTerm = false
                        dpb[i].longTermFrameIdx = op.b
                    }
                case 4:
                    maxLongTermIdx = op.a
                    for i in dpb.indices where dpb[i].longTermFrameIdx >= op.a { dpb[i].longTermFrameIdx = -1 }
                case 5:
                    for i in dpb.indices { dpb[i].shortTerm = false; dpb[i].longTermFrameIdx = -1 }
                    while bump() {}
                    epoch += 1
                    cur.epoch = epoch
                case 6:
                    for i in dpb.indices where dpb[i].longTermFrameIdx == op.b { dpb[i].longTermFrameIdx = -1 }
                    cur.longTermFrameIdx = op.b
                    currentMarked = true
                default:
                    break
                }
            }
            _ = maxLongTermIdx
        } else {
            // Sliding window.
            let numShort = dpb.filter(\.shortTerm).count, numLong = dpb.filter(\.longTerm).count
            if numShort + numLong >= max(s.maxNumRefFrames, 1) && numShort > 0 {
                var oldest = -1
                for i in dpb.indices where dpb[i].shortTerm {
                    if oldest < 0 || frameNumWrap(dpb[i], h.frameNum, maxFrameNum) < frameNumWrap(dpb[oldest], h.frameNum, maxFrameNum) { oldest = i }
                }
                if oldest >= 0 { dpb[oldest].shortTerm = false }
            }
        }
        if !currentMarked { cur.shortTerm = true }
    }

    func frameNumWrap(_ p: DecodedPicture, _ currentFrameNum: Int, _ maxFrameNum: Int) -> Int {
        p.frameNum > currentFrameNum ? p.frameNum - maxFrameNum : p.frameNum
    }

    func picNumOf(_ p: DecodedPicture, _ currentFrameNum: Int, _ maxFrameNum: Int) -> Int { frameNumWrap(p, currentFrameNum, maxFrameNum) }
}

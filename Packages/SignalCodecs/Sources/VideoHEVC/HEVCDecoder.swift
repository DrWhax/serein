// The H.265 decoder: parameter sets (from hvcC and in-band), access units of MP4 samples,
// picture order count (8.3.1), slice segments, in-loop filters, and output cropped to the
// conformance window. Errors in one picture leave the stream decodable from the next IRAP.

public import CodecCore

/// A decoded picture, cropped: planes of `bitDepth`-bit samples (UInt16), 4:2:0 or 4:0:0.
public struct HEVCFrame: Sendable {
    public var width: Int, height: Int
    public var bitDepth: Int
    public var chromaFormat: Int
    public var y: [UInt16], u: [UInt16], v: [UInt16]
    /// With `HEVCDecoder.packedOutput`: the planes as bytes instead (y/u/v empty), one per
    /// sample rounded to 8 bits, or two per sample (little-endian, `bitDepth` bits).
    public var packedY: [UInt8] = [], packedU: [UInt8] = [], packedV: [UInt8] = []
    public var packedBytesPerSample = 0
    public var poc: Int
    /// The presentation timestamp of the sample it came from.
    public var pts: Int64
    public var fullRange: Bool
    public var colourPrimaries: Int, transferCharacteristics: Int, matrixCoefficients: Int
    public var chromaWidth: Int { chromaFormat == 0 ? 0 : (width + 1) / 2 }
    public var chromaHeight: Int { chromaFormat == 0 ? 0 : (height + 1) / 2 }
}

public final class HEVCDecoder {
    var vps: [Int: HEVCVPS] = [:]
    var sps: [Int: HEVCSPS] = [:]
    var pps: [Int: HEVCPPS] = [:]
    let nalLengthSize: Int
    // POC (8.3.1).
    var prevTid0PocLsb = 0, prevTid0PocMsb = 0
    var firstPicture = true
    var noRaslOutput = false
    // The picture being decoded.
    var current: HEVCPicture?
    var currentGeometry: HEVCGeometry?
    /// The geometry of the last PPS (rebuilt only when the PPS changes).
    var geometryCache: (HEVCPPS, HEVCGeometry)?
    var currentPts: Int64 = 0
    var sliceIndex = 0
    var lastIndependentHeader: HEVCSliceHeader?
    var lastSliceAddrRs = 0
    var dependentState: (state: InlineArray<157, UInt8>, stat: [Int])?
    var wppCarry: InlineArray<157, UInt8>?
    /// Decoded pictures: references and pictures waiting for output.
    var dpb: [HEVCPicture] = []
    /// The current picture's RefPicSetStCurrBefore / StCurrAfter / LtCurr (8.3.2).
    var rpsBefore: [HEVCPicture] = [], rpsAfter: [HEVCPicture] = [], rpsLtCurr: [HEVCPicture] = []
    /// Reconstruction, the in-loop filters and output run here, behind the parser.
    let stage = HEVCReconStage()
    var nextPictureId = 0
    /// The current picture's slice segments, recorded for the stage.
    var currentSlices: [HEVCSliceWork] = []
    public private(set) var errorCount = 0
    /// How frames come out (packed on the reconstruction thread).
    public enum PackedOutput: Sendable { case none, eightBit, littleEndian16 }
    public var packedOutput = PackedOutput.none

    public init(vps vpsNALs: [[UInt8]] = [], sps spsNALs: [[UInt8]], pps ppsNALs: [[UInt8]], nalLengthSize: Int) throws(HEVCDecodeError) {
        self.nalLengthSize = nalLengthSize
        do {
            for n in vpsNALs { try handleParameterSet(try HEVCNALUnit.make(n[...])) }
            for n in spsNALs { try handleParameterSet(try HEVCNALUnit.make(n[...])) }
            for n in ppsNALs { try handleParameterSet(try HEVCNALUnit.make(n[...])) }
        } catch let e as HEVCDecodeError { throw e } catch { throw .malformed("parameter sets: \(error)") }
        guard !sps.isEmpty, !pps.isEmpty else { throw .malformed("no SPS or PPS") }
        for s in sps.values {
            guard s.chromaFormatIdc <= 1 else { throw .unsupported("chroma format \(s.chromaFormatIdc)") }
            guard s.bitDepthLuma <= 12, s.bitDepthChroma <= 12 else { throw .unsupported("\(s.bitDepthLuma)-bit video") }
        }
    }

    func handleParameterSet(_ u: HEVCNALUnit) throws {
        switch u.type {
        case HEVCNALUnit.vps: let v = try HEVCVPS.parse(u.rbsp); vps[v.id] = v
        case HEVCNALUnit.sps: let s = try HEVCSPS.parse(u.rbsp); sps[s.id] = s
        case HEVCNALUnit.pps: let p = try HEVCPPS.parse(u.rbsp, sps: sps); pps[p.id] = p
        default: break
        }
    }

    /// Decodes one MP4 sample (one access unit); returns the frames now due for output.
    public func decode(sample: ByteSlice, pts: Int64) -> [HEVCFrame] {
        let units: [HEVCNALUnit]
        do { units = try HEVCNALUnit.units(sample: sample, lengthSize: nalLengthSize) } catch { errorCount += 1; return [] }
        for u in units {
            if u.layerId != 0 { continue }
            if u.type >= 32 && u.type <= 34 {
                do { try handleParameterSet(u) } catch { errorCount += 1 }
                continue
            }
            if u.type == HEVCNALUnit.eos { firstPicture = true; continue }
            guard u.isVCL, u.type <= 21 else { continue }
            do { try decodeSlice(u, pts: pts) } catch {
                errorCount += 1
            }
        }
        finishPicture()
        return stage.drain()
    }

    /// Output of the pictures still waiting (end of stream).
    public func flush() -> [HEVCFrame] {
        finishPicture()
        bumpAll()
        stage.wait()
        return stage.drain()
    }

    func decodeSlice(_ u: HEVCNALUnit, pts: Int64) throws {
        let first = u.rbsp.first.map { $0 & 0x80 != 0 } ?? false
        if first { finishPicture() }
        let h = try HEVCSliceHeader.parse(u.rbsp, nal: u, sps: sps, pps: pps, inherit: lastIndependentHeader)
        guard let p = pps[h.ppsId], let s = sps[p.spsId] else { throw HEVCDecodeError.malformed("parameter sets") }
        if h.firstSliceSegmentInPic {
            // RASL pictures after a CRA that starts decoding (or a BLA) are skipped (8.1.3).
            if u.isIRAP { noRaslOutput = u.isIDR || u.type <= HEVCNALUnit.blaNLP || firstPicture }
            if u.isRASL && noRaslOutput { current = nil; return }
            let pic = HEVCPicture(sps: s, id: newPictureId())
            pic.poc = computePOC(u, h, s)
            pic.pts = pts
            pic.pps = p
            pic.picOutput = h.picOutput && !(u.isRASL && noRaslOutput)
            try startPicture(pic, nal: u, header: h, sps: s, pps: p)
            current = pic
            currentSlices = []
            if let (cachedPps, g) = geometryCache, cachedPps == p { currentGeometry = g } else {
                let g = HEVCGeometry(sps: s, pps: p)
                geometryCache = (p, g)
                currentGeometry = g
            }
            currentPts = pts
            sliceIndex = 0
            firstPicture = false
        } else {
            guard current != nil else { return }
            sliceIndex += 1
        }
        guard let pic = current, let geom = currentGeometry else { return }
        if !h.dependentSliceSegment {
            lastIndependentHeader = h
            lastSliceAddrRs = h.segmentAddress
        }
        let inter: HEVCInterContext? = h.type == .i ? nil : try interContext(for: pic, header: h, nal: u, sps: s, pps: p)
        if h.type == .i {
            while pic.sliceRefPocs.count <= sliceIndex { pic.sliceRefPocs.append([[], []]); pic.sliceRefLongTerm.append([[], []]) }
        }
        var d = try HEVCSliceDecoder(sps: s, pps: p, header: h, nal: u, pic: pic, geom: geom, sliceAddrRs: lastSliceAddrRs, sliceIndex: sliceIndex,
                                     dependentState: h.dependentSliceSegment ? dependentState : nil, inter: inter)
        if h.dependentSliceSegment, let carry = wppCarry { d.wppState = carry }
        try d.decode()
        currentSlices.append(d.recorded())
        dependentState = (d.endState, d.endStat)
        wppCarry = d.wppState
    }

    /// 8.3.1: PicOrderCntVal from slice_pic_order_cnt_lsb.
    func computePOC(_ u: HEVCNALUnit, _ h: HEVCSliceHeader, _ s: HEVCSPS) -> Int {
        let maxLsb = 1 << s.log2MaxPocLsb
        var msb: Int
        if u.isIRAP && noRaslOutput {
            msb = 0
        } else if h.pocLsb < prevTid0PocLsb && prevTid0PocLsb - h.pocLsb >= maxLsb / 2 {
            msb = prevTid0PocMsb + maxLsb
        } else if h.pocLsb > prevTid0PocLsb && h.pocLsb - prevTid0PocLsb > maxLsb / 2 {
            msb = prevTid0PocMsb - maxLsb
        } else {
            msb = prevTid0PocMsb
        }
        let poc = msb + h.pocLsb
        if u.temporalId == 0 && !u.isRASL && !(u.type == HEVCNALUnit.radlN || u.type == HEVCNALUnit.radlR) && !u.isSubLayerNonReference {
            prevTid0PocLsb = h.pocLsb
            prevTid0PocMsb = msb
        }
        return poc
    }

    /// 8.3.2 (reference picture set, marking, missing references) and C.5.2.2 (output and
    /// removal of pictures before the current one decodes).
    func startPicture(_ pic: HEVCPicture, nal: HEVCNALUnit, header h: HEVCSliceHeader, sps s: HEVCSPS, pps p: HEVCPPS) throws {
        rpsBefore = []
        rpsAfter = []
        rpsLtCurr = []
        if nal.isIRAP && noRaslOutput {
            // An IRAP starting a coded video sequence: earlier pictures are output (unless
            // no_output_of_prior_pics_flag), then all removed.
            if !h.noOutputOfPriorPics { bumpAll() }
            dpb.removeAll()
            return
        }
        let maxLsb = 1 << s.log2MaxPocLsb
        var used = Set<ObjectIdentifier>()
        // Long-term first (any reference picture may become long-term).
        var cycle = 0
        var ltCurr: [HEVCPicture] = []
        for (i, lt) in h.longTerm.enumerated() {
            // DeltaPocMsbCycleLt (7-52).
            cycle = i == 0 || i == h.numLongTermSps ? lt.deltaPocMsbCycle : lt.deltaPocMsbCycle + cycle
            var poc = lt.pocLsb
            if lt.msbPresent { poc += pic.poc - cycle * maxLsb - (pic.poc & (maxLsb - 1)) }
            let match = dpb.first { $0.isReference && (lt.msbPresent ? $0.poc == poc : ($0.poc & (maxLsb - 1)) == poc) }
            let ref = match ?? missingPicture(poc: poc, sps: s, longTerm: true)
            ref.isLongTerm = true
            used.insert(ObjectIdentifier(ref))
            if lt.used { ltCurr.append(ref) }
        }
        func shortTerm(_ delta: Int) -> HEVCPicture {
            let poc = pic.poc + delta
            if let m = dpb.first(where: { $0.isReference && !$0.isLongTerm && $0.poc == poc && !used.contains(ObjectIdentifier($0)) }) { return m }
            return missingPicture(poc: poc, sps: s, longTerm: false)
        }
        let rps = h.shortTermRPS
        for (d, u) in zip(rps.deltaPocS0, rps.usedS0) {
            let r = shortTerm(d)
            used.insert(ObjectIdentifier(r))
            if u { rpsBefore.append(r) }
        }
        for (d, u) in zip(rps.deltaPocS1, rps.usedS1) {
            let r = shortTerm(d)
            used.insert(ObjectIdentifier(r))
            if u { rpsAfter.append(r) }
        }
        rpsLtCurr = ltCurr
        for d in dpb where !used.contains(ObjectIdentifier(d)) { d.isReference = false }
        dpb.removeAll { !$0.neededForOutput && !$0.isReference }
        // C.5.2.2: make room before decoding.
        let dpbSize = s.maxDecPicBufferingMinus1 + 1
        while true {
            let waiting = dpb.filter(\.neededForOutput)
            guard !waiting.isEmpty, waiting.count > s.maxNumReorderPics || latencyExceeded(s) || dpb.count >= dpbSize else { break }
            bumpOne()
        }
    }

    func latencyExceeded(_ s: HEVCSPS) -> Bool {
        guard s.maxLatencyIncreasePlus1 != 0 else { return false }
        let limit = s.maxNumReorderPics + s.maxLatencyIncreasePlus1 - 1
        return dpb.contains { $0.neededForOutput && $0.latencyCount >= limit }
    }

    func newPictureId() -> Int {
        nextPictureId += 1
        return nextPictureId
    }

    /// Outputs the waiting picture first in output order (C.5.2.4).
    func bumpOne() {
        let next = dpb.filter(\.neededForOutput).min { $0.poc < $1.poc }!
        next.neededForOutput = false
        stage.output(next.id, sps: next.sps, poc: next.poc, pts: next.pts, packed: packedOutput)
        dpb.removeAll { !$0.neededForOutput && !$0.isReference }
    }

    /// 8.3.3: a reference the bitstream lost (or skipped RASL) as a grey, intra picture.
    func missingPicture(poc: Int, sps s: HEVCSPS, longTerm: Bool) -> HEVCPicture {
        let p = HEVCPicture(sps: s, id: newPictureId())
        p.poc = poc
        p.isLongTerm = longTerm
        p.neededForOutput = false
        p.picOutput = false
        for i in 0..<p.predMode.count { p.predMode[i] = 1 }
        dpb.append(p)
        errorCount += 1
        return p
    }

    /// 8.3.4: RefPicList0/1 of a slice, and the collocated picture for TMVP.
    func interContext(for pic: HEVCPicture, header h: HEVCSliceHeader, nal: HEVCNALUnit, sps: HEVCSPS, pps: HEVCPPS) throws -> HEVCInterContext {
        let total = rpsBefore.count + rpsAfter.count + rpsLtCurr.count
        guard total > 0 else { throw HEVCDecodeError.malformed("P/B slice without reference pictures") }
        var lists: [[HEVCPicture]] = [[], []], lt: [[Bool]] = [[], []]
        for l in 0..<(h.type == .b ? 2 : 1) {
            let order = l == 0 ? rpsBefore + rpsAfter : rpsAfter + rpsBefore
            let flags = [Bool](repeating: false, count: order.count) + [Bool](repeating: true, count: rpsLtCurr.count)
            let base = order + rpsLtCurr
            let n = max(h.numRefIdxActive[l], total)
            var temp: [HEVCPicture] = [], tempLT: [Bool] = []
            while temp.count < n { for (i, r) in base.enumerated() where temp.count < n { temp.append(r); tempLT.append(flags[i]) } }
            for i in 0..<h.numRefIdxActive[l] {
                let k = h.listEntry[l]?[i] ?? i
                guard k < temp.count else { throw HEVCDecodeError.malformed("list_entry \(k)") }
                lists[l].append(temp[k])
                lt[l].append(tempLT[k])
            }
        }
        var col: HEVCPicture?
        if h.temporalMvpEnabled {
            let l = h.collocatedFromL0 ? 0 : 1
            if lists[l].indices.contains(h.collocatedRefIdx) { col = lists[l][h.collocatedRefIdx] }
        }
        while pic.sliceRefPocs.count < sliceIndex { pic.sliceRefPocs.append([[], []]); pic.sliceRefLongTerm.append([[], []]) }
        if pic.sliceRefPocs.count == sliceIndex {
            pic.sliceRefPocs.append(lists.map { $0.map(\.poc) })
            pic.sliceRefLongTerm.append(lt)
        }
        return HEVCInterContext(refs: lists, refLongTerm: lt, currPoc: pic.poc, colPic: col, weights: h.predWeight)
    }

    /// The picture is parsed: it goes to the reconstruction stage, then joins the DPB / output.
    func finishPicture() {
        guard let pic = current else { return }
        current = nil
        lastIndependentHeader = nil
        if let geom = currentGeometry {
            stage.submit(HEVCPictureWork(id: pic.id, state: pic.state(), geometry: geom, pps: pic.pps, slices: currentSlices))
        }
        currentSlices = []
        // C.5.2.3: the decoded picture is a short-term reference and waits for output.
        pic.neededForOutput = pic.picOutput
        pic.isReference = true
        pic.isLongTerm = false
        for d in dpb where d.neededForOutput { d.latencyCount += 1 }
        pic.latencyCount = 0
        dpb.append(pic)
        let s = pic.sps
        while dpb.contains(where: \.neededForOutput), dpb.filter(\.neededForOutput).count > s.maxNumReorderPics || latencyExceeded(s) {
            bumpOne()
        }
        stage.keep(Set(dpb.map(\.id)))
    }

    func bumpAll() {
        while let next = dpb.filter(\.neededForOutput).min(by: { $0.poc < $1.poc }) {
            next.neededForOutput = false
            stage.output(next.id, sps: next.sps, poc: next.poc, pts: next.pts, packed: packedOutput)
        }
    }
}

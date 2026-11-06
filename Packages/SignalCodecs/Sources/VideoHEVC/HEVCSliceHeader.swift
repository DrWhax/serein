// slice_segment_header() (H.265 7.3.6.1), with ref_pic_lists_modification (7.3.6.2) and
// pred_weight_table (7.3.6.3). A dependent slice segment copies its slice's header
// (`inherit`) and reads only its own address and entry points.

public import CodecCore

public struct HEVCPredWeight: Sendable, Equatable {
    public var lumaLog2Denom = 0, chromaLog2Denom = 0
    /// Per list, per reference: luma (weight, offset), chroma Cb/Cr (weight, offset).
    public var luma: [[(w: Int, o: Int)]] = [[], []]
    public var chroma: [[[(w: Int, o: Int)]]] = [[], []]

    public static func == (a: HEVCPredWeight, b: HEVCPredWeight) -> Bool {
        a.lumaLog2Denom == b.lumaLog2Denom && a.chromaLog2Denom == b.chromaLog2Denom
            && a.luma.map { $0.map { [$0.w, $0.o] } } == b.luma.map { $0.map { [$0.w, $0.o] } }
            && a.chroma.map { $0.map { $0.map { [$0.w, $0.o] } } } == b.chroma.map { $0.map { $0.map { [$0.w, $0.o] } } }
    }
}

public struct HEVCSliceHeader: Sendable, Equatable {
    public enum SliceType: Int, Sendable { case b = 0, p = 1, i = 2 }

    public var firstSliceSegmentInPic = true
    public var noOutputOfPriorPics = false
    public var ppsId = 0
    public var dependentSliceSegment = false
    public var segmentAddress = 0
    public var type: SliceType = .i
    public var picOutput = true
    public var colourPlaneId = 0
    public var pocLsb = 0
    /// The short-term RPS in use (the SPS's, or coded in the header).
    public var shortTermRPS = HEVCShortTermRPS()
    /// Bits the header's own st_ref_pic_set took (for hardware-style offsets; 0 from the SPS).
    public var shortTermRPSBits = 0
    /// Long-term entries: POC LSB (or full POC when msb present), used flag, MSB present.
    public var longTerm: [(pocLsb: Int, used: Bool, msbPresent: Bool, deltaPocMsbCycle: Int)] = []
    /// num_long_term_sps: entries of `longTerm` taken from the SPS (DeltaPocMsbCycleLt restarts after them).
    public var numLongTermSps = 0
    public var temporalMvpEnabled = false
    public var saoLuma = false, saoChroma = false
    public var numRefIdxActive = [0, 0]
    /// list_entry_lX when modification is present (indices into the candidate list).
    public var listEntry: [[Int]?] = [nil, nil]
    public var mvdL1Zero = false
    public var cabacInit = false
    public var collocatedFromL0 = true
    public var collocatedRefIdx = 0
    public var predWeight: HEVCPredWeight?
    public var maxNumMergeCand = 5
    public var qpDelta = 0
    public var cbQpOffset = 0, crQpOffset = 0
    public var deblockingFilterDisabled = false
    public var betaOffsetDiv2 = 0, tcOffsetDiv2 = 0
    public var loopFilterAcrossSlices = false
    public var entryPointOffsets: [Int] = []
    /// Where slice_segment_data() starts in the RBSP (bytes).
    public var dataOffset = 0

    public static func == (a: HEVCSliceHeader, b: HEVCSliceHeader) -> Bool {
        a.firstSliceSegmentInPic == b.firstSliceSegmentInPic && a.ppsId == b.ppsId && a.dependentSliceSegment == b.dependentSliceSegment
            && a.segmentAddress == b.segmentAddress && a.type == b.type && a.pocLsb == b.pocLsb && a.shortTermRPS == b.shortTermRPS
            && a.numRefIdxActive == b.numRefIdxActive && a.qpDelta == b.qpDelta && a.maxNumMergeCand == b.maxNumMergeCand
            && a.entryPointOffsets == b.entryPointOffsets && a.dataOffset == b.dataOffset && a.collocatedRefIdx == b.collocatedRefIdx
            && a.saoLuma == b.saoLuma && a.saoChroma == b.saoChroma && a.predWeight == b.predWeight
    }

    /// NumPicTotalCurr (7-55): pictures the current one may reference.
    public var numPicTotalCurr: Int { shortTermRPS.numUsed + longTerm.filter(\.used).count }

    /// Parses a slice segment header; `inherit` is the header of the slice this dependent
    /// segment belongs to (required when dependent_slice_segment_flag is 1).
    public static func parse(_ rbsp: [UInt8], nal: HEVCNALUnit, sps spsById: [Int: HEVCSPS], pps ppsById: [Int: HEVCPPS],
                             inherit: HEVCSliceHeader?) throws(ParseFailure) -> HEVCSliceHeader {
        var r = HEVCReader(rbsp)
        var h = HEVCSliceHeader()
        h.firstSliceSegmentInPic = try r.flag("first_slice_segment_in_pic_flag")
        if nal.isIRAP { h.noOutputOfPriorPics = try r.flag("no_output_of_prior_pics_flag") }
        h.ppsId = try r.ue("slice_pic_parameter_set_id", 0...63)
        guard let pps = ppsById[h.ppsId] else { throw r.fail("slice_pic_parameter_set_id", "unknown PPS \(h.ppsId)") }
        guard let sps = spsById[pps.spsId] else { throw r.fail("slice_pic_parameter_set_id", "unknown SPS \(pps.spsId)") }
        if !h.firstSliceSegmentInPic {
            if pps.dependentSliceSegmentsEnabled { h.dependentSliceSegment = try r.flag("dependent_slice_segment_flag") }
            h.segmentAddress = try r.u(ceilLog2(sps.picSizeInCtbs), "slice_segment_address")
            guard h.segmentAddress < sps.picSizeInCtbs else { throw r.fail("slice_segment_address", "\(h.segmentAddress) beyond the picture") }
        }
        if h.dependentSliceSegment {
            guard var base = inherit else { throw r.fail("dependent_slice_segment_flag", "no slice to depend on") }
            base.firstSliceSegmentInPic = false
            base.dependentSliceSegment = true
            base.segmentAddress = h.segmentAddress
            base.noOutputOfPriorPics = h.noOutputOfPriorPics
            h = base
        } else {
            try r.skip(pps.numExtraSliceHeaderBits, "slice_reserved_flag")
            guard let type = SliceType(rawValue: try r.ue("slice_type", 0...2)) else { throw r.fail("slice_type", "invalid") }
            h.type = type
            if nal.isIRAP && type != .i && nal.layerId == 0 { throw r.fail("slice_type", "IRAP picture with a P/B slice") }
            if pps.outputFlagPresent { h.picOutput = try r.flag("pic_output_flag") }
            if sps.separateColourPlane { h.colourPlaneId = try r.u(2, "colour_plane_id") }
            if !nal.isIDR {
                h.pocLsb = try r.u(sps.log2MaxPocLsb, "slice_pic_order_cnt_lsb")
                if !(try r.flag("short_term_ref_pic_set_sps_flag")) {
                    let start = r.position
                    h.shortTermRPS = try HEVCShortTermRPS.parse(&r, index: sps.shortTermRPS.count, numInSPS: sps.shortTermRPS.count, sets: sps.shortTermRPS)
                    h.shortTermRPSBits = r.position - start
                } else {
                    guard !sps.shortTermRPS.isEmpty else { throw r.fail("short_term_ref_pic_set_sps_flag", "the SPS has no sets") }
                    let idx = sps.shortTermRPS.count > 1 ? try r.u(ceilLog2(sps.shortTermRPS.count), "short_term_ref_pic_set_idx") : 0
                    guard idx < sps.shortTermRPS.count else { throw r.fail("short_term_ref_pic_set_idx", "\(idx)") }
                    h.shortTermRPS = sps.shortTermRPS[idx]
                }
                if sps.longTermRefPicsPresent {
                    var numSps = 0
                    if !sps.ltRefPicPocLsbSps.isEmpty { numSps = try r.ue("num_long_term_sps", 0...sps.ltRefPicPocLsbSps.count) }
                    h.numLongTermSps = numSps
                    let numPics = try r.ue("num_long_term_pics", 0...(16 - numSps))
                    for i in 0..<(numSps + numPics) {
                        var lsb = 0, used = false
                        if i < numSps {
                            let idx = sps.ltRefPicPocLsbSps.count > 1 ? try r.u(ceilLog2(sps.ltRefPicPocLsbSps.count), "lt_idx_sps") : 0
                            guard idx < sps.ltRefPicPocLsbSps.count else { throw r.fail("lt_idx_sps", "\(idx)") }
                            lsb = sps.ltRefPicPocLsbSps[idx]
                            used = sps.usedByCurrPicLtSps[idx]
                        } else {
                            lsb = try r.u(sps.log2MaxPocLsb, "poc_lsb_lt")
                            used = try r.flag("used_by_curr_pic_lt_flag")
                        }
                        let msb = try r.flag("delta_poc_msb_present_flag")
                        let cycle = msb ? try r.ue("delta_poc_msb_cycle_lt") : 0
                        h.longTerm.append((lsb, used, msb, cycle))
                    }
                }
                if sps.temporalMvpEnabled { h.temporalMvpEnabled = try r.flag("slice_temporal_mvp_enabled_flag") }
            }
            if sps.saoEnabled {
                h.saoLuma = try r.flag("slice_sao_luma_flag")
                if sps.chromaArrayType != 0 { h.saoChroma = try r.flag("slice_sao_chroma_flag") }
            }
            if type != .i {
                h.numRefIdxActive = [pps.numRefIdxL0DefaultActive, type == .b ? pps.numRefIdxL1DefaultActive : 0]
                if try r.flag("num_ref_idx_active_override_flag") {
                    h.numRefIdxActive[0] = try r.ue("num_ref_idx_l0_active_minus1", 0...14) + 1
                    if type == .b { h.numRefIdxActive[1] = try r.ue("num_ref_idx_l1_active_minus1", 0...14) + 1 }
                }
                guard h.numPicTotalCurr > 0 else { throw r.fail("slice_type", "a P/B slice with no reference pictures") }
                if pps.listsModificationPresent && h.numPicTotalCurr > 1 {
                    let bits = ceilLog2(h.numPicTotalCurr)
                    for l in 0..<(type == .b ? 2 : 1) where try r.flag("ref_pic_list_modification_flag_l\(l)") {
                        var entries: [Int] = []
                        for _ in 0..<h.numRefIdxActive[l] {
                            let e = try r.u(bits, "list_entry_l\(l)")
                            guard e < h.numPicTotalCurr else { throw r.fail("list_entry_l\(l)", "\(e)") }
                            entries.append(e)
                        }
                        h.listEntry[l] = entries
                    }
                }
                if type == .b { h.mvdL1Zero = try r.flag("mvd_l1_zero_flag") }
                if pps.cabacInitPresent { h.cabacInit = try r.flag("cabac_init_flag") }
                if h.temporalMvpEnabled {
                    if type == .b { h.collocatedFromL0 = try r.flag("collocated_from_l0_flag") }
                    let list = h.collocatedFromL0 ? 0 : 1
                    if h.numRefIdxActive[list] > 1 { h.collocatedRefIdx = try r.ue("collocated_ref_idx", 0...(h.numRefIdxActive[list] - 1)) }
                }
                if (pps.weightedPred && type == .p) || (pps.weightedBipred && type == .b) {
                    h.predWeight = try parsePredWeight(&r, h, sps)
                }
                h.maxNumMergeCand = 5 - (try r.ue("five_minus_max_num_merge_cand", 0...4))
            }
            h.qpDelta = try r.se("slice_qp_delta")
            let qp = pps.initQp + h.qpDelta
            guard (-(6 * (sps.bitDepthLuma - 8))...51).contains(qp) else { throw r.fail("slice_qp_delta", "SliceQpY \(qp)") }
            if pps.sliceChromaQpOffsetsPresent {
                h.cbQpOffset = try r.se("slice_cb_qp_offset", -12...12)
                h.crQpOffset = try r.se("slice_cr_qp_offset", -12...12)
                guard (-12...12).contains(pps.cbQpOffset + h.cbQpOffset), (-12...12).contains(pps.crQpOffset + h.crQpOffset) else {
                    throw r.fail("slice_cb_qp_offset", "combined chroma offset out of range")
                }
            }
            if pps.chromaQpOffsetListEnabled { _ = try r.flag("cu_chroma_qp_offset_enabled_flag") }
            var override = false
            if pps.deblockingFilterOverrideEnabled { override = try r.flag("deblocking_filter_override_flag") }
            h.deblockingFilterDisabled = pps.deblockingFilterDisabled
            h.betaOffsetDiv2 = pps.betaOffsetDiv2
            h.tcOffsetDiv2 = pps.tcOffsetDiv2
            if override {
                h.deblockingFilterDisabled = try r.flag("slice_deblocking_filter_disabled_flag")
                if !h.deblockingFilterDisabled {
                    h.betaOffsetDiv2 = try r.se("slice_beta_offset_div2", -6...6)
                    h.tcOffsetDiv2 = try r.se("slice_tc_offset_div2", -6...6)
                }
            }
            h.loopFilterAcrossSlices = pps.loopFilterAcrossSlices
            if pps.loopFilterAcrossSlices && (h.saoLuma || h.saoChroma || !h.deblockingFilterDisabled) {
                h.loopFilterAcrossSlices = try r.flag("slice_loop_filter_across_slices_enabled_flag")
            }
        }
        h.entryPointOffsets = []
        if pps.tilesEnabled || pps.entropyCodingSync {
            let maxEntries = pps.tilesEnabled && pps.entropyCodingSync ? pps.tileColumnWidths.count * sps.heightCtbs - 1
                : pps.tilesEnabled ? pps.tileColumnWidths.count * pps.tileRowHeights.count - 1 : sps.heightCtbs - 1
            let n = try r.ue("num_entry_point_offsets", 0...maxEntries)
            if n > 0 {
                let len = try r.ue("offset_len_minus1", 0...31) + 1
                for _ in 0..<n { h.entryPointOffsets.append(try r.u(len, "entry_point_offset_minus1") + 1) }
            }
        }
        if pps.sliceSegmentHeaderExtensionPresent {
            let len = try r.ue("slice_segment_header_extension_length", 0...256)
            try r.skip(len * 8, "slice_segment_header_extension_data_byte")
        }
        try r.byteAlignment("byte_alignment")
        h.dataOffset = r.position / 8
        guard h.dataOffset <= rbsp.count else { throw r.fail("slice_segment_data", "header past the NAL unit") }
        return h
    }

    static func parsePredWeight(_ r: inout HEVCReader, _ h: HEVCSliceHeader, _ sps: HEVCSPS) throws(ParseFailure) -> HEVCPredWeight {
        var w = HEVCPredWeight()
        w.lumaLog2Denom = try r.ue("luma_log2_weight_denom", 0...7)
        let chroma = sps.chromaArrayType != 0
        if chroma { w.chromaLog2Denom = w.lumaLog2Denom + (try r.se("delta_chroma_log2_weight_denom", (-w.lumaLog2Denom)...(7 - w.lumaLog2Denom))) }
        let offsetShift = sps.highPrecisionOffsetsEnabled ? 0 : sps.bitDepthLuma - 8
        let offsetRange = sps.highPrecisionOffsetsEnabled ? (1 << (sps.bitDepthLuma - 1)) : 128
        for l in 0..<(h.type == .b ? 2 : 1) {
            let n = h.numRefIdxActive[l]
            // Single-layer, no current-picture referencing: every reference has another POC.
            var lumaFlags: [Bool] = [], chromaFlags: [Bool] = []
            for _ in 0..<n { lumaFlags.append(try r.flag("luma_weight_l\(l)_flag")) }
            if chroma { for _ in 0..<n { chromaFlags.append(try r.flag("chroma_weight_l\(l)_flag")) } } else { chromaFlags = [Bool](repeating: false, count: n) }
            for i in 0..<n {
                var luma = (w: 1 << w.lumaLog2Denom, o: 0)
                if lumaFlags[i] {
                    luma.w += try r.se("delta_luma_weight_l\(l)", -128...127)
                    luma.o = (try r.se("luma_offset_l\(l)", (-offsetRange)...(offsetRange - 1))) << offsetShift
                }
                w.luma[l].append(luma)
                var cs: [(w: Int, o: Int)] = []
                for _ in 0..<2 {
                    var c = (w: 1 << w.chromaLog2Denom, o: 0)
                    if chromaFlags[i] {
                        c.w += try r.se("delta_chroma_weight_l\(l)", -128...127)
                        let delta = try r.se("delta_chroma_offset_l\(l)", (-4 * offsetRange)...(4 * offsetRange - 1))
                        // (7-56)
                        let o = (offsetRange - ((offsetRange * c.w) >> w.chromaLog2Denom)) + delta
                        c.o = max(-offsetRange, min(offsetRange - 1, o)) << offsetShift
                    }
                    cs.append(c)
                }
                w.chroma[l].append(cs)
            }
        }
        return w
    }
}

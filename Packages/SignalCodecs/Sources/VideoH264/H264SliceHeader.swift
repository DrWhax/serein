// slice_header() (H.264 7.3.3) with ref_pic_list_modification (7.3.3.1), pred_weight_table
// (7.3.3.2) and dec_ref_pic_marking (7.3.3.3), for frame (non-field) pictures.

import CodecCore

public enum H264SliceType: Int, Sendable { case p = 0, b = 1, i = 2, sp = 3, si = 4 }

public struct H264SliceHeader: Sendable {
    public var firstMb = 0
    public var type: H264SliceType = .i
    public var ppsId = 0
    public var frameNum = 0
    public var idr = false
    public var nalRefIdc = 0
    public var idrPicId = 0
    public var pocLsb = 0
    public var deltaPocBottom = 0
    public var deltaPoc = (0, 0)
    public var redundantPicCnt = 0
    public var directSpatialMvPred = false
    public var numRefIdxActive = (l0: 0, l1: 0)
    /// (modification_of_pic_nums_idc, value) per list.
    public var refModifications: [[(Int, Int)]] = [[], []]
    /// Explicit weights: [list][refIdx] → (luma w, o, chroma (w, o) × 2); nil when not present.
    public var lumaLog2Denom = 0, chromaLog2Denom = 0
    public var weights: [[H264Weight]]?
    public var noOutputOfPriorPics = false
    public var longTermReference = false
    public var adaptiveRefMarking = false
    /// (memory_management_control_operation, a, b).
    public var mmco: [(op: Int, a: Int, b: Int)] = []
    public var cabacInitIdc = 0
    public var qpDelta = 0
    public var disableDeblocking = 0
    public var alphaOffset = 0, betaOffset = 0

    public var isIntra: Bool { type == .i || type == .si }
}

public struct H264Weight: Sendable, Equatable {
    public var lumaWeight: Int, lumaOffset: Int
    public var chromaWeight: (Int, Int), chromaOffset: (Int, Int)
    public var lumaFlag: Bool, chromaFlag: Bool

    public static func == (a: H264Weight, b: H264Weight) -> Bool {
        a.lumaWeight == b.lumaWeight && a.lumaOffset == b.lumaOffset && a.chromaWeight == b.chromaWeight && a.chromaOffset == b.chromaOffset
    }
}

extension H264SliceHeader {
    /// Parses the header; returns it and the reader positioned at slice_data().
    static func parse(_ nal: NALUnit, sps: (Int) -> H264SPS?, pps: (Int) -> H264PPS?) throws(ParseFailure) -> (H264SliceHeader, H264Reader, H264SPS, H264PPS) {
        var r = H264Reader(nal.rbsp)
        var h = H264SliceHeader()
        h.idr = nal.type == NALUnit.sliceIDR
        h.nalRefIdc = nal.refIdc
        h.firstMb = try r.ue("slice.first_mb_in_slice")
        let st = try r.ue("slice.slice_type", 0 ... 9)
        guard let type = H264SliceType(rawValue: st % 5) else { throw r.fail("slice.slice_type", "\(st)") }
        guard type != .sp && type != .si else { throw r.fail("slice.slice_type", "SP/SI slices are not supported") }
        h.type = type
        if h.idr && type != .i { throw r.fail("slice.slice_type", "IDR picture with a non-I slice") }
        h.ppsId = try r.ue("slice.pic_parameter_set_id", 0 ... 255)
        guard let p = pps(h.ppsId) else { throw r.fail("slice.pic_parameter_set_id", "unknown PPS \(h.ppsId)") }
        guard let s = sps(p.spsId) else { throw r.fail("pps.seq_parameter_set_id", "unknown SPS \(p.spsId)") }
        guard h.firstMb < s.widthMbs * s.heightMbs else { throw r.fail("slice.first_mb_in_slice", "\(h.firstMb)") }
        h.frameNum = try r.u(s.log2MaxFrameNum, "slice.frame_num")
        // frame_mbs_only: no field_pic_flag.
        if h.idr { h.idrPicId = try r.ue("slice.idr_pic_id", 0 ... 65535) }
        if s.pocType == 0 {
            h.pocLsb = try r.u(s.log2MaxPocLsb, "slice.pic_order_cnt_lsb")
            if p.bottomFieldPicOrderInFramePresent { h.deltaPocBottom = try r.se("slice.delta_pic_order_cnt_bottom") }
        }
        if s.pocType == 1 && !s.deltaPicOrderAlwaysZero {
            h.deltaPoc.0 = try r.se("slice.delta_pic_order_cnt[0]")
            if p.bottomFieldPicOrderInFramePresent { h.deltaPoc.1 = try r.se("slice.delta_pic_order_cnt[1]") }
        }
        if p.redundantPicCntPresent { h.redundantPicCnt = try r.ue("slice.redundant_pic_cnt", 0 ... 127) }
        if type == .b { h.directSpatialMvPred = try r.flag("slice.direct_spatial_mv_pred_flag") }
        h.numRefIdxActive = type == .i ? (0, 0) : (p.numRefIdxDefault.l0, type == .b ? p.numRefIdxDefault.l1 : 0)
        if type == .p || type == .b {
            if try r.flag("slice.num_ref_idx_active_override_flag") {
                h.numRefIdxActive.l0 = 1 + (try r.ue("slice.num_ref_idx_l0_active_minus1", 0 ... 31))
                if type == .b { h.numRefIdxActive.l1 = 1 + (try r.ue("slice.num_ref_idx_l1_active_minus1", 0 ... 31)) }
            }
            // Frames: at most 16 references per list.
            guard h.numRefIdxActive.l0 <= 16, h.numRefIdxActive.l1 <= 16 else { throw r.fail("slice.num_ref_idx_active", "more than 16 for frames") }
        }
        // ref_pic_list_modification()
        for list in 0 ..< (type == .b ? 2 : type == .p ? 1 : 0) {
            if try r.flag("slice.ref_pic_list_modification_flag") {
                while true {
                    let idc = try r.ue("slice.modification_of_pic_nums_idc", 0 ... 5)
                    if idc == 3 { break }
                    guard idc <= 2 else { throw r.fail("slice.modification_of_pic_nums_idc", "MVC modification") }
                    let v = try r.ue(idc == 2 ? "slice.long_term_pic_num" : "slice.abs_diff_pic_num_minus1")
                    h.refModifications[list].append((idc, v))
                    guard h.refModifications[list].count <= 33 else { throw r.fail("slice.ref_pic_list_modification", "too many") }
                }
            }
        }
        if (p.weightedPred && type == .p) || (p.weightedBipredIdc == 1 && type == .b) { try parseWeights(&r, &h) }
        if nal.refIdc != 0 {
            if h.idr {
                h.noOutputOfPriorPics = try r.flag("slice.no_output_of_prior_pics_flag")
                h.longTermReference = try r.flag("slice.long_term_reference_flag")
            } else {
                h.adaptiveRefMarking = try r.flag("slice.adaptive_ref_pic_marking_mode_flag")
                if h.adaptiveRefMarking {
                    while true {
                        let op = try r.ue("slice.memory_management_control_operation", 0 ... 6)
                        if op == 0 { break }
                        var a = 0, b = 0
                        if op == 1 || op == 3 { a = try r.ue("slice.difference_of_pic_nums_minus1") }
                        if op == 2 { a = try r.ue("slice.long_term_pic_num") }
                        if op == 3 || op == 6 { b = try r.ue("slice.long_term_frame_idx", 0 ... 15) }
                        if op == 4 { a = try r.ue("slice.max_long_term_frame_idx_plus1", 0 ... 16) }
                        h.mmco.append((op, a, b))
                        guard h.mmco.count <= 66 else { throw r.fail("slice.dec_ref_pic_marking", "too many operations") }
                    }
                }
            }
        }
        if p.cabac && type != .i { h.cabacInitIdc = try r.ue("slice.cabac_init_idc", 0 ... 2) }
        h.qpDelta = try r.se("slice.slice_qp_delta", -(26 + p.picInitQp) - 26 ... 51)
        guard (0 ... 51).contains(p.picInitQp + h.qpDelta) else { throw r.fail("slice.slice_qp_delta", "QP out of range") }
        if p.deblockingFilterControlPresent {
            h.disableDeblocking = try r.ue("slice.disable_deblocking_filter_idc", 0 ... 2)
            if h.disableDeblocking != 1 {
                h.alphaOffset = 2 * (try r.se("slice.slice_alpha_c0_offset_div2", -6 ... 6))
                h.betaOffset = 2 * (try r.se("slice.slice_beta_offset_div2", -6 ... 6))
            }
        }
        return (h, r, s, p)
    }

    static func parseWeights(_ r: inout H264Reader, _ h: inout H264SliceHeader) throws(ParseFailure) {
        h.lumaLog2Denom = try r.ue("pred_weight_table.luma_log2_weight_denom", 0 ... 7)
        h.chromaLog2Denom = try r.ue("pred_weight_table.chroma_log2_weight_denom", 0 ... 7)
        var all: [[H264Weight]] = []
        for list in 0 ..< (h.type == .b ? 2 : 1) {
            var ws: [H264Weight] = []
            for _ in 0 ..< (list == 0 ? h.numRefIdxActive.l0 : h.numRefIdxActive.l1) {
                var w = H264Weight(lumaWeight: 1 << h.lumaLog2Denom, lumaOffset: 0, chromaWeight: (1 << h.chromaLog2Denom, 1 << h.chromaLog2Denom),
                                   chromaOffset: (0, 0), lumaFlag: false, chromaFlag: false)
                if try r.flag("pred_weight_table.luma_weight_flag") {
                    w.lumaFlag = true
                    w.lumaWeight = try r.se("pred_weight_table.luma_weight", -128 ... 127)
                    w.lumaOffset = try r.se("pred_weight_table.luma_offset", -128 ... 127)
                }
                if try r.flag("pred_weight_table.chroma_weight_flag") {
                    w.chromaFlag = true
                    let w0 = try r.se("pred_weight_table.chroma_weight", -128 ... 127), o0 = try r.se("pred_weight_table.chroma_offset", -128 ... 127)
                    let w1 = try r.se("pred_weight_table.chroma_weight", -128 ... 127), o1 = try r.se("pred_weight_table.chroma_offset", -128 ... 127)
                    w.chromaWeight = (w0, w1)
                    w.chromaOffset = (o0, o1)
                }
                ws.append(w)
            }
            all.append(ws)
        }
        h.weights = all
    }
}

// Sequence and picture parameter sets (H.264 7.3.2.1, 7.3.2.2) and their limits. Supported:
// 8-bit 4:2:0 progressive (frame_mbs_only) Baseline/Main/Extended-without-data-partitioning/
// High; one slice group; up to 16 reference frames; pictures up to 8192×8192 luma and
// 36 864 macroblocks… per the level limits checked against MaxFS.

public import CodecCore

public struct H264SPS: Sendable, Equatable {
    public var profileIdc = 0
    public var constraintFlags = 0
    public var levelIdc = 0
    public var id = 0
    public var chromaFormatIdc = 1
    public var bitDepthLuma = 8, bitDepthChroma = 8
    public var transformBypass = false
    /// Scaling lists in raster order (nil: flat 16), 6 × 4x4 then 2 × 8x8 (luma intra/inter).
    public var scaling4: [[UInt8]]?
    public var scaling8: [[UInt8]]?
    public var log2MaxFrameNum = 4
    public var pocType = 0
    public var log2MaxPocLsb = 4
    public var deltaPicOrderAlwaysZero = false
    public var offsetForNonRefPic = 0
    public var offsetForTopToBottomField = 0
    public var offsetForRefFrame: [Int] = []
    public var maxNumRefFrames = 0
    public var gapsInFrameNumAllowed = false
    public var widthMbs = 0, heightMbs = 0
    public var frameMbsOnly = true
    public var direct8x8Inference = true
    public var crop = (left: 0, right: 0, top: 0, bottom: 0)
    // VUI (the parts the decoder uses).
    public var maxNumReorderFrames: Int?
    public var maxDecFrameBuffering: Int?
    public var videoFullRange = false
    public var colourPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2

    public static func == (a: H264SPS, b: H264SPS) -> Bool {
        a.profileIdc == b.profileIdc && a.levelIdc == b.levelIdc && a.id == b.id && a.widthMbs == b.widthMbs && a.heightMbs == b.heightMbs
            && a.log2MaxFrameNum == b.log2MaxFrameNum && a.pocType == b.pocType && a.log2MaxPocLsb == b.log2MaxPocLsb
            && a.maxNumRefFrames == b.maxNumRefFrames && a.scaling4 == b.scaling4 && a.scaling8 == b.scaling8
            && a.crop == b.crop && a.direct8x8Inference == b.direct8x8Inference && a.offsetForRefFrame == b.offsetForRefFrame
    }

    public var width: Int { widthMbs * 16 - 2 * (crop.left + crop.right) }
    public var height: Int { heightMbs * 16 - 2 * (crop.top + crop.bottom) }

    static let maxMacroblocks = 139_264   // level 6.2 MaxFS
    static let maxDimensionMbs = 512      // 8192 px

    public static func parse(_ rbsp: [UInt8]) throws(ParseFailure) -> H264SPS {
        var r = H264Reader(rbsp)
        var s = H264SPS()
        s.profileIdc = try r.u(8, "sps.profile_idc")
        s.constraintFlags = try r.u(8, "sps.constraint_set_flags")
        s.levelIdc = try r.u(8, "sps.level_idc")
        s.id = try r.ue("sps.seq_parameter_set_id", 0 ... 31)
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(s.profileIdc) {
            s.chromaFormatIdc = try r.ue("sps.chroma_format_idc", 0 ... 3)
            if s.chromaFormatIdc == 3 { _ = try r.flag("sps.separate_colour_plane_flag") }
            s.bitDepthLuma = 8 + (try r.ue("sps.bit_depth_luma_minus8", 0 ... 6))
            s.bitDepthChroma = 8 + (try r.ue("sps.bit_depth_chroma_minus8", 0 ... 6))
            s.transformBypass = try r.flag("sps.qpprime_y_zero_transform_bypass_flag")
            if try r.flag("sps.seq_scaling_matrix_present_flag") {
                let (l4, l8) = try parseScalingLists(&r, count8: s.chromaFormatIdc == 3 ? 6 : 2, fallback4: nil, fallback8: nil)
                s.scaling4 = l4
                s.scaling8 = l8
            }
        }
        guard s.chromaFormatIdc == 1 else { throw r.fail("sps.chroma_format_idc", "only 4:2:0 is supported") }
        guard s.bitDepthLuma == 8, s.bitDepthChroma == 8 else { throw r.fail("sps.bit_depth", "only 8-bit is supported") }
        guard !s.transformBypass else { throw r.fail("sps.qpprime_y_zero_transform_bypass_flag", "lossless is not supported") }
        s.log2MaxFrameNum = 4 + (try r.ue("sps.log2_max_frame_num_minus4", 0 ... 12))
        s.pocType = try r.ue("sps.pic_order_cnt_type", 0 ... 2)
        if s.pocType == 0 {
            s.log2MaxPocLsb = 4 + (try r.ue("sps.log2_max_pic_order_cnt_lsb_minus4", 0 ... 12))
        } else if s.pocType == 1 {
            s.deltaPicOrderAlwaysZero = try r.flag("sps.delta_pic_order_always_zero_flag")
            s.offsetForNonRefPic = try r.se("sps.offset_for_non_ref_pic", -(1 << 31) + 1 ... (1 << 31) - 1)
            s.offsetForTopToBottomField = try r.se("sps.offset_for_top_to_bottom_field", -(1 << 31) + 1 ... (1 << 31) - 1)
            let n = try r.ue("sps.num_ref_frames_in_pic_order_cnt_cycle", 0 ... 255)
            for _ in 0 ..< n { s.offsetForRefFrame.append(try r.se("sps.offset_for_ref_frame", -(1 << 31) + 1 ... (1 << 31) - 1)) }
        }
        s.maxNumRefFrames = try r.ue("sps.max_num_ref_frames", 0 ... 16)
        s.gapsInFrameNumAllowed = try r.flag("sps.gaps_in_frame_num_value_allowed_flag")
        s.widthMbs = 1 + (try r.ue("sps.pic_width_in_mbs_minus1", 0 ... maxDimensionMbs - 1))
        let heightUnits = 1 + (try r.ue("sps.pic_height_in_map_units_minus1", 0 ... maxDimensionMbs - 1))
        s.frameMbsOnly = try r.flag("sps.frame_mbs_only_flag")
        guard s.frameMbsOnly else { throw r.fail("sps.frame_mbs_only_flag", "interlaced (field / MBAFF) coding is not supported") }
        s.heightMbs = heightUnits
        guard s.widthMbs * s.heightMbs <= maxMacroblocks else { throw r.fail("sps.size", "\(s.widthMbs)×\(s.heightMbs) macroblocks") }
        s.direct8x8Inference = try r.flag("sps.direct_8x8_inference_flag")
        if try r.flag("sps.frame_cropping_flag") {
            let l = try r.ue("sps.frame_crop_left_offset"), rr = try r.ue("sps.frame_crop_right_offset")
            let t = try r.ue("sps.frame_crop_top_offset"), b = try r.ue("sps.frame_crop_bottom_offset")
            guard 2 * (l + rr) < s.widthMbs * 16, 2 * (t + b) < s.heightMbs * 16 else { throw r.fail("sps.frame_crop", "crop exceeds the picture") }
            s.crop = (l, rr, t, b)
        }
        if try r.flag("sps.vui_parameters_present_flag") { try parseVUI(&r, &s) }
        return s
    }

    static func parseVUI(_ r: inout H264Reader, _ s: inout H264SPS) throws(ParseFailure) {
        if try r.flag("vui.aspect_ratio_info_present_flag") {
            if try r.u(8, "vui.aspect_ratio_idc") == 255 { _ = try r.u(16, "vui.sar_width"); _ = try r.u(16, "vui.sar_height") }
        }
        if try r.flag("vui.overscan_info_present_flag") { _ = try r.flag("vui.overscan_appropriate_flag") }
        if try r.flag("vui.video_signal_type_present_flag") {
            _ = try r.u(3, "vui.video_format")
            s.videoFullRange = try r.flag("vui.video_full_range_flag")
            if try r.flag("vui.colour_description_present_flag") {
                s.colourPrimaries = try r.u(8, "vui.colour_primaries")
                s.transferCharacteristics = try r.u(8, "vui.transfer_characteristics")
                s.matrixCoefficients = try r.u(8, "vui.matrix_coefficients")
            }
        }
        if try r.flag("vui.chroma_loc_info_present_flag") { _ = try r.ue("vui.chroma_sample_loc_type_top"); _ = try r.ue("vui.chroma_sample_loc_type_bottom") }
        if try r.flag("vui.timing_info_present_flag") { _ = try r.u(32, "vui.num_units_in_tick"); _ = try r.u(32, "vui.time_scale"); _ = try r.flag("vui.fixed_frame_rate_flag") }
        let nal = try r.flag("vui.nal_hrd_parameters_present_flag")
        if nal { try skipHRD(&r) }
        let vcl = try r.flag("vui.vcl_hrd_parameters_present_flag")
        if vcl { try skipHRD(&r) }
        if nal || vcl { _ = try r.flag("vui.low_delay_hrd_flag") }
        _ = try r.flag("vui.pic_struct_present_flag")
        if try r.flag("vui.bitstream_restriction_flag") {
            _ = try r.flag("vui.motion_vectors_over_pic_boundaries_flag")
            _ = try r.ue("vui.max_bytes_per_pic_denom")
            _ = try r.ue("vui.max_bits_per_mb_denom")
            _ = try r.ue("vui.log2_max_mv_length_horizontal")
            _ = try r.ue("vui.log2_max_mv_length_vertical")
            s.maxNumReorderFrames = try r.ue("vui.max_num_reorder_frames", 0 ... 16)
            s.maxDecFrameBuffering = try r.ue("vui.max_dec_frame_buffering", 0 ... 16)
        }
    }

    static func skipHRD(_ r: inout H264Reader) throws(ParseFailure) {
        let count = 1 + (try r.ue("hrd.cpb_cnt_minus1", 0 ... 31))
        _ = try r.u(4, "hrd.bit_rate_scale"); _ = try r.u(4, "hrd.cpb_size_scale")
        for _ in 0 ..< count { _ = try r.ue("hrd.bit_rate_value_minus1"); _ = try r.ue("hrd.cpb_size_value_minus1"); _ = try r.flag("hrd.cbr_flag") }
        _ = try r.u(5, "hrd.initial_cpb_removal_delay_length_minus1"); _ = try r.u(5, "hrd.cpb_removal_delay_length_minus1")
        _ = try r.u(5, "hrd.dpb_output_delay_length_minus1"); _ = try r.u(5, "hrd.time_offset_length")
    }

    /// Zigzag (frame) scan positions → raster index.
    static let zigzag4: [Int] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
    static let zigzag8: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static var defaults4: [[UInt8]] { (0 ..< 6).map { Array(H264Tables.defaultScaling4[($0 < 3 ? 0 : 1) * 16 ..< ($0 < 3 ? 0 : 1) * 16 + 16]) } }
    static var defaults8: [[UInt8]] { (0 ..< 6).map { Array(H264Tables.defaultScaling8[($0 % 2) * 64 ..< ($0 % 2) * 64 + 64]) } }

    /// scaling_list() × 6 (+ 2 or 6 8x8) with the fall-back rules of Table 7-2 (rule A for the
    /// SPS: defaults; rule B for the PPS: the SPS lists).
    static func parseScalingLists(_ r: inout H264Reader, count8: Int, fallback4: [[UInt8]]?, fallback8: [[UInt8]]?) throws(ParseFailure) -> ([[UInt8]], [[UInt8]]) {
        var l4: [[UInt8]] = [], l8: [[UInt8]] = []
        for i in 0 ..< 6 {
            if try r.flag("scaling_list_present_flag") {
                l4.append(try scalingList(&r, size: 16, defaultList: defaults4[i]) ?? defaults4[i])
            } else {
                // Fall back to the previous list of the same kind, or the default / SPS list.
                l4.append(i == 0 || i == 3 ? (fallback4?[i] ?? defaults4[i]) : l4[i - 1])
            }
        }
        for i in 0 ..< count8 {
            if try r.flag("scaling_list_present_flag") {
                l8.append(try scalingList(&r, size: 64, defaultList: defaults8[i]) ?? defaults8[i])
            } else {
                l8.append(i < 2 ? (fallback8?[i] ?? defaults8[i]) : l8[i - 2])
            }
        }
        return (l4, l8)
    }

    /// One scaling_list(): nil means "use the default" (useDefaultScalingMatrixFlag).
    static func scalingList(_ r: inout H264Reader, size: Int, defaultList: [UInt8]) throws(ParseFailure) -> [UInt8]? {
        let scan = size == 16 ? zigzag4 : zigzag8
        var list = [UInt8](repeating: 0, count: size)
        var last = 8, next = 8
        for j in 0 ..< size {
            if next != 0 {
                let delta = try r.se("scaling_list.delta_scale", -128 ... 127)
                next = (last + delta + 256) % 256
                if j == 0 && next == 0 { return nil }
            }
            let v = next == 0 ? last : next
            list[scan[j]] = UInt8(v)
            last = v
        }
        return list
    }
}

public struct H264PPS: Sendable, Equatable {
    public var id = 0
    public var spsId = 0
    public var cabac = false
    public var bottomFieldPicOrderInFramePresent = false
    public var numRefIdxDefault = (l0: 1, l1: 1)
    public var weightedPred = false
    public var weightedBipredIdc = 0
    public var picInitQp = 26
    public var picInitQs = 26
    public var chromaQpIndexOffset = 0
    public var secondChromaQpIndexOffset = 0
    public var deblockingFilterControlPresent = false
    public var constrainedIntraPred = false
    public var redundantPicCntPresent = false
    public var transform8x8Mode = false
    public var scaling4: [[UInt8]]?
    public var scaling8: [[UInt8]]?

    public static func == (a: H264PPS, b: H264PPS) -> Bool {
        a.id == b.id && a.spsId == b.spsId && a.cabac == b.cabac && a.numRefIdxDefault == b.numRefIdxDefault && a.weightedPred == b.weightedPred
            && a.weightedBipredIdc == b.weightedBipredIdc && a.picInitQp == b.picInitQp && a.chromaQpIndexOffset == b.chromaQpIndexOffset
            && a.secondChromaQpIndexOffset == b.secondChromaQpIndexOffset && a.deblockingFilterControlPresent == b.deblockingFilterControlPresent
            && a.constrainedIntraPred == b.constrainedIntraPred && a.transform8x8Mode == b.transform8x8Mode
            && a.scaling4 == b.scaling4 && a.scaling8 == b.scaling8 && a.redundantPicCntPresent == b.redundantPicCntPresent
    }

    public static func parse(_ rbsp: [UInt8], sps: (Int) -> H264SPS?) throws(ParseFailure) -> H264PPS {
        var r = H264Reader(rbsp)
        var p = H264PPS()
        p.id = try r.ue("pps.pic_parameter_set_id", 0 ... 255)
        p.spsId = try r.ue("pps.seq_parameter_set_id", 0 ... 31)
        guard let s = sps(p.spsId) else { throw r.fail("pps.seq_parameter_set_id", "unknown SPS \(p.spsId)") }
        p.cabac = try r.flag("pps.entropy_coding_mode_flag")
        p.bottomFieldPicOrderInFramePresent = try r.flag("pps.bottom_field_pic_order_in_frame_present_flag")
        let groups = 1 + (try r.ue("pps.num_slice_groups_minus1", 0 ... 7))
        guard groups == 1 else { throw r.fail("pps.num_slice_groups_minus1", "flexible macroblock ordering is not supported") }
        p.numRefIdxDefault = (1 + (try r.ue("pps.num_ref_idx_l0_default_active_minus1", 0 ... 31)), 1 + (try r.ue("pps.num_ref_idx_l1_default_active_minus1", 0 ... 31)))
        p.weightedPred = try r.flag("pps.weighted_pred_flag")
        p.weightedBipredIdc = try r.u(2, "pps.weighted_bipred_idc")
        guard p.weightedBipredIdc != 3 else { throw r.fail("pps.weighted_bipred_idc", "3") }
        p.picInitQp = 26 + (try r.se("pps.pic_init_qp_minus26", -26 ... 25))
        p.picInitQs = 26 + (try r.se("pps.pic_init_qs_minus26", -26 ... 25))
        p.chromaQpIndexOffset = try r.se("pps.chroma_qp_index_offset", -12 ... 12)
        p.deblockingFilterControlPresent = try r.flag("pps.deblocking_filter_control_present_flag")
        p.constrainedIntraPred = try r.flag("pps.constrained_intra_pred_flag")
        p.redundantPicCntPresent = try r.flag("pps.redundant_pic_cnt_present_flag")
        p.secondChromaQpIndexOffset = p.chromaQpIndexOffset
        if r.moreRBSPData() {
            p.transform8x8Mode = try r.flag("pps.transform_8x8_mode_flag")
            if try r.flag("pps.pic_scaling_matrix_present_flag") {
                let fb4 = s.scaling4 ?? H264SPS.defaults4, fb8 = s.scaling8 ?? H264SPS.defaults8
                let (l4, l8) = try H264SPS.parseScalingLists(&r, count8: p.transform8x8Mode ? 2 : 0, fallback4: fb4, fallback8: fb8)
                p.scaling4 = l4
                p.scaling8 = p.transform8x8Mode ? l8 : nil
            }
            p.secondChromaQpIndexOffset = try r.se("pps.second_chroma_qp_index_offset", -12 ... 12)
        }
        return p
    }
}

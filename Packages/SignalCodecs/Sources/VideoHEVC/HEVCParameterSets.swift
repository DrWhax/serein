// H.265 parameter sets (7.3.2.1 VPS, 7.3.2.2 SPS, 7.3.2.3 PPS), with profile_tier_level
// (7.3.3), scaling_list_data (7.3.4), st_ref_pic_set (7.3.7, derivation 7.4.8), VUI (E.2.1)
// and hrd_parameters (E.2.2). Every value is bounded as 7.4.3 states before it is used.

public import CodecCore

/// profile_tier_level(1, maxNumSubLayersMinus1): only the general profile is kept.
public struct HEVCProfileTierLevel: Sendable, Equatable {
    public var profileSpace = 0, tier = 0, profileIdc = 0
    public var compatibility: UInt32 = 0
    public var progressiveSource = false, interlacedSource = false
    public var levelIdc = 0

    static func parse(_ r: inout HEVCReader, maxSubLayersMinus1: Int) throws(ParseFailure) -> HEVCProfileTierLevel {
        var p = HEVCProfileTierLevel()
        p.profileSpace = try r.u(2, "general_profile_space")
        p.tier = try r.u(1, "general_tier_flag")
        p.profileIdc = try r.u(5, "general_profile_idc")
        p.compatibility = UInt32(try r.u(32, "general_profile_compatibility_flags"))
        p.progressiveSource = try r.flag("general_progressive_source_flag")
        p.interlacedSource = try r.flag("general_interlaced_source_flag")
        try r.skip(2 + 43 + 1, "general_constraint_flags")
        p.levelIdc = try r.u(8, "general_level_idc")
        var profilePresent = [Bool](), levelPresent = [Bool]()
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(try r.flag("sub_layer_profile_present_flag"))
            levelPresent.append(try r.flag("sub_layer_level_present_flag"))
        }
        if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { try r.skip(2, "reserved_zero_2bits") } }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { try r.skip(88, "sub_layer_profile") }
            if levelPresent[i] { try r.skip(8, "sub_layer_level_idc") }
        }
        return p
    }
}

/// ScalingFactor inputs: per sizeId (4x4, 8x8, 16x16, 32x32) and matrixId (intra Y Cb Cr,
/// inter Y Cb Cr) the coefficients in up-right diagonal order, and the DC values (16/32).
public struct HEVCScalingList: Sendable, Equatable {
    public var lists: [[[Int]]]
    public var dc: [[Int]]

    /// Table 7-5 / 7-6 defaults.
    public static let defaultIntra8: [Int] = [16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18, 17, 18, 18, 17, 18, 21, 19, 20,
                                             21, 20, 19, 21, 24, 22, 22, 24, 24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31,
                                             29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115]
    public static let defaultInter8: [Int] = [16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 20, 20, 20,
                                             20, 20, 20, 20, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28,
                                             28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91]

    static func defaults(sizeId: Int, matrixId: Int) -> [Int] {
        if sizeId == 0 { return [Int](repeating: 16, count: 16) }
        return matrixId < 3 ? defaultIntra8 : defaultInter8
    }

    public static var `default`: HEVCScalingList {
        var l = HEVCScalingList(lists: [], dc: [])
        for sizeId in 0..<4 {
            l.lists.append((0..<6).map { defaults(sizeId: sizeId, matrixId: $0) })
            l.dc.append([Int](repeating: 16, count: 6))
        }
        return l
    }

    /// scaling_list_data() (7.3.4); for 32x32 only matrixId 0 and 3 are coded (chroma 32x32
    /// copies the 16x16 lists, 7.4.5, for ChromaArrayType 3; unused in 4:2:0).
    static func parse(_ r: inout HEVCReader) throws(ParseFailure) -> HEVCScalingList {
        var l = HEVCScalingList.default
        for sizeId in 0..<4 {
            var matrixId = 0
            while matrixId < 6 {
                let step = sizeId == 3 ? 3 : 1
                if !(try r.flag("scaling_list_pred_mode_flag")) {
                    let delta = try r.ue("scaling_list_pred_matrix_id_delta", 0...(sizeId == 3 ? matrixId / 3 : matrixId))
                    if delta == 0 {
                        l.lists[sizeId][matrixId] = defaults(sizeId: sizeId, matrixId: matrixId)
                        l.dc[sizeId][matrixId] = 16
                    } else {
                        let ref = matrixId - delta * step
                        l.lists[sizeId][matrixId] = l.lists[sizeId][ref]
                        l.dc[sizeId][matrixId] = l.dc[sizeId][ref]
                    }
                } else {
                    var next = 8
                    let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 {
                        next = try r.se("scaling_list_dc_coef_minus8", -7...247) + 8
                        l.dc[sizeId][matrixId] = next
                    }
                    var list = [Int](repeating: 0, count: coefNum)
                    for i in 0..<coefNum {
                        next = (next + (try r.se("scaling_list_delta_coef", -128...127)) + 256) % 256
                        list[i] = next
                    }
                    l.lists[sizeId][matrixId] = list
                    if sizeId <= 1 { l.dc[sizeId][matrixId] = list[0] }
                }
                matrixId += step
            }
        }
        // 32x32 chroma (matrixId 1, 2, 4, 5): from 16x16 (7.4.5, ChromaArrayType == 3 only).
        for m in [1, 2, 4, 5] {
            l.lists[3][m] = l.lists[2][m]
            l.dc[3][m] = l.dc[2][m]
        }
        return l
    }
}

/// A short-term reference picture set (7.4.8): delta POCs, negative then positive.
public struct HEVCShortTermRPS: Sendable, Equatable {
    public var deltaPocS0: [Int] = []
    public var usedS0: [Bool] = []
    public var deltaPocS1: [Int] = []
    public var usedS1: [Bool] = []
    public var numDeltaPocs: Int { deltaPocS0.count + deltaPocS1.count }
    public var numUsed: Int { usedS0.filter { $0 }.count + usedS1.filter { $0 }.count }

    /// st_ref_pic_set(stRpsIdx); `sets` holds the SPS's sets parsed so far (inter-RPS refs).
    static func parse(_ r: inout HEVCReader, index: Int, numInSPS: Int, sets: [HEVCShortTermRPS]) throws(ParseFailure) -> HEVCShortTermRPS {
        var interPred = false
        if index != 0 { interPred = try r.flag("inter_ref_pic_set_prediction_flag") }
        var out = HEVCShortTermRPS()
        if interPred {
            var deltaIdx = 1
            if index == numInSPS { deltaIdx = try r.ue("delta_idx_minus1", 0...(index - 1)) + 1 }
            let refIdx = index - deltaIdx
            guard sets.indices.contains(refIdx) else { throw r.fail("delta_idx_minus1", "no reference RPS \(refIdx)") }
            let ref = sets[refIdx]
            let sign = try r.flag("delta_rps_sign")
            let absDelta = try r.ue("abs_delta_rps_minus1", 0...32767) + 1
            let deltaRps = sign ? -absDelta : absDelta
            var used = [Bool](), useDelta = [Bool]()
            for _ in 0...ref.numDeltaPocs {
                let u = try r.flag("used_by_curr_pic_flag")
                used.append(u)
                useDelta.append(u ? true : try r.flag("use_delta_flag"))
            }
            let nNeg = ref.deltaPocS0.count, nDelta = ref.numDeltaPocs
            // (7-61)
            for j in stride(from: ref.deltaPocS1.count - 1, through: 0, by: -1) {
                let d = ref.deltaPocS1[j] + deltaRps
                if d < 0 && useDelta[nNeg + j] { out.deltaPocS0.append(d); out.usedS0.append(used[nNeg + j]) }
            }
            if deltaRps < 0 && useDelta[nDelta] { out.deltaPocS0.append(deltaRps); out.usedS0.append(used[nDelta]) }
            for j in 0..<nNeg {
                let d = ref.deltaPocS0[j] + deltaRps
                if d < 0 && useDelta[j] { out.deltaPocS0.append(d); out.usedS0.append(used[j]) }
            }
            // (7-62)
            for j in stride(from: nNeg - 1, through: 0, by: -1) {
                let d = ref.deltaPocS0[j] + deltaRps
                if d > 0 && useDelta[j] { out.deltaPocS1.append(d); out.usedS1.append(used[j]) }
            }
            if deltaRps > 0 && useDelta[nDelta] { out.deltaPocS1.append(deltaRps); out.usedS1.append(used[nDelta]) }
            for j in 0..<ref.deltaPocS1.count {
                let d = ref.deltaPocS1[j] + deltaRps
                if d > 0 && useDelta[nNeg + j] { out.deltaPocS1.append(d); out.usedS1.append(used[nNeg + j]) }
            }
        } else {
            let neg = try r.ue("num_negative_pics", 0...16), pos = try r.ue("num_positive_pics", 0...16)
            guard neg + pos <= 16 else { throw r.fail("num_positive_pics", "\(neg + pos) pictures") }
            var poc = 0
            for _ in 0..<neg {
                poc -= try r.ue("delta_poc_s0_minus1", 0...32767) + 1
                out.deltaPocS0.append(poc)
                out.usedS0.append(try r.flag("used_by_curr_pic_s0_flag"))
            }
            poc = 0
            for _ in 0..<pos {
                poc += try r.ue("delta_poc_s1_minus1", 0...32767) + 1
                out.deltaPocS1.append(poc)
                out.usedS1.append(try r.flag("used_by_curr_pic_s1_flag"))
            }
        }
        guard out.numDeltaPocs <= 16 else { throw r.fail("st_ref_pic_set", "\(out.numDeltaPocs) pictures") }
        return out
    }
}

public struct HEVCVPS: Sendable, Equatable {
    public var id = 0
    public var maxSubLayersMinus1 = 0

    static func parse(_ rbsp: [UInt8]) throws(ParseFailure) -> HEVCVPS {
        var r = HEVCReader(rbsp)
        var v = HEVCVPS()
        v.id = try r.u(4, "vps_video_parameter_set_id")
        try r.skip(2 + 6, "vps_base_layer_flags_and_max_layers")
        v.maxSubLayersMinus1 = try r.u(3, "vps_max_sub_layers_minus1")
        return v
    }
}

public struct HEVCSPS: Sendable, Equatable {
    public var vpsId = 0
    public var maxSubLayersMinus1 = 0
    public var ptl = HEVCProfileTierLevel()
    public var id = 0
    public var chromaFormatIdc = 1
    public var separateColourPlane = false
    public var width = 0, height = 0
    public var conformanceWindow = (left: 0, right: 0, top: 0, bottom: 0)
    public var bitDepthLuma = 8, bitDepthChroma = 8
    public var log2MaxPocLsb = 4
    public var maxDecPicBufferingMinus1 = 0, maxNumReorderPics = 0, maxLatencyIncreasePlus1 = 0
    public var log2MinCbSize = 3, log2CtbSize = 4
    public var log2MinTbSize = 2, log2MaxTbSize = 5
    public var maxTransformHierarchyDepthInter = 0, maxTransformHierarchyDepthIntra = 0
    public var scalingListEnabled = false
    /// The SPS's own lists (nil: flat, or defaults when enabled without data).
    public var scalingList: HEVCScalingList?
    public var ampEnabled = false
    public var saoEnabled = false
    public var pcmEnabled = false
    public var pcmBitDepthLuma = 8, pcmBitDepthChroma = 8
    public var log2MinPcmCbSize = 3, log2MaxPcmCbSize = 3
    public var pcmLoopFilterDisabled = false
    public var shortTermRPS: [HEVCShortTermRPS] = []
    public var longTermRefPicsPresent = false
    public var ltRefPicPocLsbSps: [Int] = []
    public var usedByCurrPicLtSps: [Bool] = []
    public var temporalMvpEnabled = false
    public var strongIntraSmoothing = false
    // VUI (the parts the decoder and the renderer use).
    public var videoFullRange = false
    public var colourPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2
    // Range extension (sps_range_extension, 7.3.2.2.2): all false for Main / Main10.
    public var transformSkipRotationEnabled = false, transformSkipContextEnabled = false, implicitRdpcmEnabled = false
    public var explicitRdpcmEnabled = false, extendedPrecisionProcessing = false, intraSmoothingDisabled = false
    public var highPrecisionOffsetsEnabled = false, persistentRiceAdaptationEnabled = false, cabacBypassAlignmentEnabled = false

    /// ChromaArrayType: 0 for monochrome or separate planes, else chroma_format_idc.
    public var chromaArrayType: Int { separateColourPlane ? 0 : chromaFormatIdc }
    public var ctbSize: Int { 1 << log2CtbSize }
    public var widthCtbs: Int { (width + ctbSize - 1) >> log2CtbSize }
    public var heightCtbs: Int { (height + ctbSize - 1) >> log2CtbSize }
    public var picSizeInCtbs: Int { widthCtbs * heightCtbs }
    public var subWidthC: Int { chromaFormatIdc == 1 || chromaFormatIdc == 2 ? 2 : 1 }
    public var subHeightC: Int { chromaFormatIdc == 1 ? 2 : 1 }

    public static func == (a: HEVCSPS, b: HEVCSPS) -> Bool {
        a.id == b.id && a.width == b.width && a.height == b.height && a.chromaFormatIdc == b.chromaFormatIdc && a.bitDepthLuma == b.bitDepthLuma
            && a.bitDepthChroma == b.bitDepthChroma && a.log2CtbSize == b.log2CtbSize && a.log2MinCbSize == b.log2MinCbSize
            && a.shortTermRPS == b.shortTermRPS && a.scalingList == b.scalingList && a.conformanceWindow == b.conformanceWindow
            && a.log2MaxPocLsb == b.log2MaxPocLsb && a.saoEnabled == b.saoEnabled && a.pcmEnabled == b.pcmEnabled && a.ampEnabled == b.ampEnabled
    }

    /// The decoder's limits: up to 8192 × 4320 (level 6.2) and 8/10-bit 4:0:0 or 4:2:0.
    public static let maxDimension = 8192

    public static func parse(_ rbsp: [UInt8]) throws(ParseFailure) -> HEVCSPS {
        var r = HEVCReader(rbsp)
        var s = HEVCSPS()
        s.vpsId = try r.u(4, "sps_video_parameter_set_id")
        s.maxSubLayersMinus1 = try r.u(3, "sps_max_sub_layers_minus1")
        guard s.maxSubLayersMinus1 <= 6 else { throw r.fail("sps_max_sub_layers_minus1", "\(s.maxSubLayersMinus1)") }
        _ = try r.flag("sps_temporal_id_nesting_flag")
        s.ptl = try HEVCProfileTierLevel.parse(&r, maxSubLayersMinus1: s.maxSubLayersMinus1)
        s.id = try r.ue("sps_seq_parameter_set_id", 0...15)
        s.chromaFormatIdc = try r.ue("chroma_format_idc", 0...3)
        if s.chromaFormatIdc == 3 { s.separateColourPlane = try r.flag("separate_colour_plane_flag") }
        s.width = try r.ue("pic_width_in_luma_samples", 1...maxDimension)
        s.height = try r.ue("pic_height_in_luma_samples", 1...maxDimension)
        if try r.flag("conformance_window_flag") {
            let l = try r.ue("conf_win_left_offset", 0...maxDimension), rt = try r.ue("conf_win_right_offset", 0...maxDimension)
            let t = try r.ue("conf_win_top_offset", 0...maxDimension), b = try r.ue("conf_win_bottom_offset", 0...maxDimension)
            s.conformanceWindow = (l, rt, t, b)
        }
        s.bitDepthLuma = try r.ue("bit_depth_luma_minus8", 0...8) + 8
        s.bitDepthChroma = try r.ue("bit_depth_chroma_minus8", 0...8) + 8
        s.log2MaxPocLsb = try r.ue("log2_max_pic_order_cnt_lsb_minus4", 0...12) + 4
        let subLayerOrdering = try r.flag("sps_sub_layer_ordering_info_present_flag")
        for _ in (subLayerOrdering ? 0 : s.maxSubLayersMinus1)...s.maxSubLayersMinus1 {
            s.maxDecPicBufferingMinus1 = try r.ue("sps_max_dec_pic_buffering_minus1", 0...15)
            s.maxNumReorderPics = try r.ue("sps_max_num_reorder_pics", 0...s.maxDecPicBufferingMinus1)
            s.maxLatencyIncreasePlus1 = try r.ue("sps_max_latency_increase_plus1")
        }
        s.log2MinCbSize = try r.ue("log2_min_luma_coding_block_size_minus3", 0...3) + 3
        s.log2CtbSize = s.log2MinCbSize + (try r.ue("log2_diff_max_min_luma_coding_block_size", 0...3))
        guard (4...6).contains(s.log2CtbSize) else { throw r.fail("log2_diff_max_min_luma_coding_block_size", "CTB 2^\(s.log2CtbSize)") }
        s.log2MinTbSize = try r.ue("log2_min_luma_transform_block_size_minus2", 0...3) + 2
        s.log2MaxTbSize = s.log2MinTbSize + (try r.ue("log2_diff_max_min_luma_transform_block_size", 0...3))
        guard s.log2MinTbSize < s.log2MinCbSize, s.log2MaxTbSize <= min(s.log2CtbSize, 5) else { throw r.fail("log2_transform_block_size", "invalid") }
        s.maxTransformHierarchyDepthInter = try r.ue("max_transform_hierarchy_depth_inter", 0...(s.log2CtbSize - s.log2MinTbSize))
        s.maxTransformHierarchyDepthIntra = try r.ue("max_transform_hierarchy_depth_intra", 0...(s.log2CtbSize - s.log2MinTbSize))
        s.scalingListEnabled = try r.flag("scaling_list_enabled_flag")
        if s.scalingListEnabled {
            s.scalingList = try r.flag("sps_scaling_list_data_present_flag") ? try HEVCScalingList.parse(&r) : .default
        }
        s.ampEnabled = try r.flag("amp_enabled_flag")
        s.saoEnabled = try r.flag("sample_adaptive_offset_enabled_flag")
        s.pcmEnabled = try r.flag("pcm_enabled_flag")
        if s.pcmEnabled {
            s.pcmBitDepthLuma = try r.u(4, "pcm_sample_bit_depth_luma_minus1") + 1
            s.pcmBitDepthChroma = try r.u(4, "pcm_sample_bit_depth_chroma_minus1") + 1
            guard s.pcmBitDepthLuma <= s.bitDepthLuma, s.pcmBitDepthChroma <= s.bitDepthChroma else { throw r.fail("pcm_sample_bit_depth", "deeper than the picture") }
            s.log2MinPcmCbSize = try r.ue("log2_min_pcm_luma_coding_block_size_minus3", 0...2) + 3
            s.log2MaxPcmCbSize = s.log2MinPcmCbSize + (try r.ue("log2_diff_max_min_pcm_luma_coding_block_size", 0...2))
            guard s.log2MinPcmCbSize >= s.log2MinCbSize, s.log2MaxPcmCbSize <= min(s.log2CtbSize, 5) else { throw r.fail("pcm_block_size", "invalid") }
            s.pcmLoopFilterDisabled = try r.flag("pcm_loop_filter_disabled_flag")
        }
        let numST = try r.ue("num_short_term_ref_pic_sets", 0...64)
        for i in 0..<numST { s.shortTermRPS.append(try HEVCShortTermRPS.parse(&r, index: i, numInSPS: numST, sets: s.shortTermRPS)) }
        s.longTermRefPicsPresent = try r.flag("long_term_ref_pics_present_flag")
        if s.longTermRefPicsPresent {
            let n = try r.ue("num_long_term_ref_pics_sps", 0...32)
            for _ in 0..<n {
                s.ltRefPicPocLsbSps.append(try r.u(s.log2MaxPocLsb, "lt_ref_pic_poc_lsb_sps"))
                s.usedByCurrPicLtSps.append(try r.flag("used_by_curr_pic_lt_sps_flag"))
            }
        }
        s.temporalMvpEnabled = try r.flag("sps_temporal_mvp_enabled_flag")
        s.strongIntraSmoothing = try r.flag("strong_intra_smoothing_enabled_flag")
        if try r.flag("vui_parameters_present_flag") { try parseVUI(&r, &s) }
        if try r.flag("sps_extension_present_flag") {
            let range = try r.flag("sps_range_extension_flag")
            _ = try r.u(7, "sps_extension_flags")
            if range {
                s.transformSkipRotationEnabled = try r.flag("transform_skip_rotation_enabled_flag")
                s.transformSkipContextEnabled = try r.flag("transform_skip_context_enabled_flag")
                s.implicitRdpcmEnabled = try r.flag("implicit_rdpcm_enabled_flag")
                s.explicitRdpcmEnabled = try r.flag("explicit_rdpcm_enabled_flag")
                s.extendedPrecisionProcessing = try r.flag("extended_precision_processing_flag")
                s.intraSmoothingDisabled = try r.flag("intra_smoothing_disabled_flag")
                s.highPrecisionOffsetsEnabled = try r.flag("high_precision_offsets_enabled_flag")
                s.persistentRiceAdaptationEnabled = try r.flag("persistent_rice_adaptation_enabled_flag")
                s.cabacBypassAlignmentEnabled = try r.flag("cabac_bypass_alignment_enabled_flag")
            }
        }
        guard s.width % (1 << s.log2MinCbSize) == 0, s.height % (1 << s.log2MinCbSize) == 0 else {
            throw r.fail("pic_size", "not a multiple of the minimum coding block")
        }
        return s
    }

    static func parseVUI(_ r: inout HEVCReader, _ s: inout HEVCSPS) throws(ParseFailure) {
        if try r.flag("aspect_ratio_info_present_flag") {
            if try r.u(8, "aspect_ratio_idc") == 255 { try r.skip(32, "sar_width_height") }
        }
        if try r.flag("overscan_info_present_flag") { _ = try r.flag("overscan_appropriate_flag") }
        if try r.flag("video_signal_type_present_flag") {
            _ = try r.u(3, "video_format")
            s.videoFullRange = try r.flag("video_full_range_flag")
            if try r.flag("colour_description_present_flag") {
                s.colourPrimaries = try r.u(8, "colour_primaries")
                s.transferCharacteristics = try r.u(8, "transfer_characteristics")
                s.matrixCoefficients = try r.u(8, "matrix_coeffs")
            }
        }
        if try r.flag("chroma_loc_info_present_flag") {
            _ = try r.ue("chroma_sample_loc_type_top_field", 0...5)
            _ = try r.ue("chroma_sample_loc_type_bottom_field", 0...5)
        }
        _ = try r.flag("neutral_chroma_indication_flag")
        _ = try r.flag("field_seq_flag")
        _ = try r.flag("frame_field_info_present_flag")
        if try r.flag("default_display_window_flag") { for _ in 0..<4 { _ = try r.ue("def_disp_win_offset") } }
        if try r.flag("vui_timing_info_present_flag") {
            try r.skip(64, "vui_num_units_in_tick_and_time_scale")
            if try r.flag("vui_poc_proportional_to_timing_flag") { _ = try r.ue("vui_num_ticks_poc_diff_one_minus1") }
            if try r.flag("vui_hrd_parameters_present_flag") { try parseHRD(&r, common: true, maxSubLayersMinus1: s.maxSubLayersMinus1) }
        }
        if try r.flag("bitstream_restriction_flag") {
            try r.skip(3, "bitstream_restriction_flags")
            for rule in ["min_spatial_segmentation_idc", "max_bytes_per_pic_denom", "max_bits_per_min_cu_denom",
                         "log2_max_mv_length_horizontal", "log2_max_mv_length_vertical"] { _ = try r.ue(rule) }
        }
    }

    /// hrd_parameters() (E.2.2): parsed only to reach the fields after it.
    static func parseHRD(_ r: inout HEVCReader, common: Bool, maxSubLayersMinus1: Int) throws(ParseFailure) {
        var nal = false, vcl = false, subPic = false
        if common {
            nal = try r.flag("nal_hrd_parameters_present_flag")
            vcl = try r.flag("vcl_hrd_parameters_present_flag")
            if nal || vcl {
                subPic = try r.flag("sub_pic_hrd_params_present_flag")
                if subPic { try r.skip(8 + 5 + 1 + 5, "sub_pic_hrd_params") }
                try r.skip(4 + 4, "bit_rate_scale_cpb_size_scale")
                if subPic { try r.skip(4, "cpb_size_du_scale") }
                try r.skip(5 + 5 + 5, "hrd_delay_lengths")
            }
        }
        for _ in 0...maxSubLayersMinus1 {
            let fixedGeneral = try r.flag("fixed_pic_rate_general_flag")
            let fixedWithinCVS = fixedGeneral ? true : try r.flag("fixed_pic_rate_within_cvs_flag")
            var lowDelay = false
            if fixedWithinCVS { _ = try r.ue("elemental_duration_in_tc_minus1", 0...2047) } else { lowDelay = try r.flag("low_delay_hrd_flag") }
            var cpbCnt = 1
            if !lowDelay { cpbCnt = try r.ue("cpb_cnt_minus1", 0...31) + 1 }
            for present in [nal, vcl] where present {
                for _ in 0..<cpbCnt {
                    _ = try r.ue("bit_rate_value_minus1")
                    _ = try r.ue("cpb_size_value_minus1")
                    if subPic { _ = try r.ue("cpb_size_du_value_minus1"); _ = try r.ue("bit_rate_du_value_minus1") }
                    _ = try r.flag("cbr_flag")
                }
            }
        }
    }
}

public struct HEVCPPS: Sendable, Equatable {
    public var id = 0
    public var spsId = 0
    public var dependentSliceSegmentsEnabled = false
    public var outputFlagPresent = false
    public var numExtraSliceHeaderBits = 0
    public var signDataHiding = false
    public var cabacInitPresent = false
    public var numRefIdxL0DefaultActive = 1, numRefIdxL1DefaultActive = 1
    public var initQp = 26
    public var constrainedIntraPred = false
    public var transformSkipEnabled = false
    public var cuQpDeltaEnabled = false
    public var diffCuQpDeltaDepth = 0
    public var cbQpOffset = 0, crQpOffset = 0
    public var sliceChromaQpOffsetsPresent = false
    public var weightedPred = false, weightedBipred = false
    public var transquantBypassEnabled = false
    public var tilesEnabled = false
    public var entropyCodingSync = false
    /// Tile column widths / row heights in CTBs (6.5.1); one tile without tiles.
    public var tileColumnWidths: [Int] = []
    public var tileRowHeights: [Int] = []
    public var loopFilterAcrossTiles = true
    public var loopFilterAcrossSlices = false
    public var deblockingFilterOverrideEnabled = false
    public var deblockingFilterDisabled = false
    public var betaOffsetDiv2 = 0, tcOffsetDiv2 = 0
    public var scalingList: HEVCScalingList?
    public var listsModificationPresent = false
    public var log2ParallelMergeLevel = 2
    public var sliceSegmentHeaderExtensionPresent = false
    // Range extension (7.3.2.3.2).
    public var log2MaxTransformSkipSize = 2
    public var crossComponentPrediction = false
    public var chromaQpOffsetListEnabled = false

    /// pic_parameter_set_rbsp(); the tile layout needs the SPS (6.5.1).
    public static func parse(_ rbsp: [UInt8], sps: [Int: HEVCSPS]) throws(ParseFailure) -> HEVCPPS {
        var r = HEVCReader(rbsp)
        var p = HEVCPPS()
        p.id = try r.ue("pps_pic_parameter_set_id", 0...63)
        p.spsId = try r.ue("pps_seq_parameter_set_id", 0...15)
        guard let s = sps[p.spsId] else { throw r.fail("pps_seq_parameter_set_id", "unknown SPS \(p.spsId)") }
        p.dependentSliceSegmentsEnabled = try r.flag("dependent_slice_segments_enabled_flag")
        p.outputFlagPresent = try r.flag("output_flag_present_flag")
        p.numExtraSliceHeaderBits = try r.u(3, "num_extra_slice_header_bits")
        p.signDataHiding = try r.flag("sign_data_hiding_enabled_flag")
        p.cabacInitPresent = try r.flag("cabac_init_present_flag")
        p.numRefIdxL0DefaultActive = try r.ue("num_ref_idx_l0_default_active_minus1", 0...14) + 1
        p.numRefIdxL1DefaultActive = try r.ue("num_ref_idx_l1_default_active_minus1", 0...14) + 1
        p.initQp = 26 + (try r.se("init_qp_minus26", -(26 + 6 * (s.bitDepthLuma - 8))...25))
        p.constrainedIntraPred = try r.flag("constrained_intra_pred_flag")
        p.transformSkipEnabled = try r.flag("transform_skip_enabled_flag")
        p.cuQpDeltaEnabled = try r.flag("cu_qp_delta_enabled_flag")
        if p.cuQpDeltaEnabled { p.diffCuQpDeltaDepth = try r.ue("diff_cu_qp_delta_depth", 0...(s.log2CtbSize - s.log2MinCbSize)) }
        p.cbQpOffset = try r.se("pps_cb_qp_offset", -12...12)
        p.crQpOffset = try r.se("pps_cr_qp_offset", -12...12)
        p.sliceChromaQpOffsetsPresent = try r.flag("pps_slice_chroma_qp_offsets_present_flag")
        p.weightedPred = try r.flag("weighted_pred_flag")
        p.weightedBipred = try r.flag("weighted_bipred_flag")
        p.transquantBypassEnabled = try r.flag("transquant_bypass_enabled_flag")
        p.tilesEnabled = try r.flag("tiles_enabled_flag")
        p.entropyCodingSync = try r.flag("entropy_coding_sync_enabled_flag")
        p.tileColumnWidths = [s.widthCtbs]
        p.tileRowHeights = [s.heightCtbs]
        if p.tilesEnabled {
            let cols = try r.ue("num_tile_columns_minus1", 0...(s.widthCtbs - 1)) + 1
            let rows = try r.ue("num_tile_rows_minus1", 0...(s.heightCtbs - 1)) + 1
            guard cols * rows > 1 else { throw r.fail("num_tile_columns_minus1", "tiles enabled with one tile") }
            if try r.flag("uniform_spacing_flag") {
                p.tileColumnWidths = (0..<cols).map { ($0 + 1) * s.widthCtbs / cols - $0 * s.widthCtbs / cols }
                p.tileRowHeights = (0..<rows).map { ($0 + 1) * s.heightCtbs / rows - $0 * s.heightCtbs / rows }
            } else {
                var w: [Int] = [], h: [Int] = []
                for _ in 0..<(cols - 1) { w.append(try r.ue("column_width_minus1", 0...(s.widthCtbs - 1)) + 1) }
                for _ in 0..<(rows - 1) { h.append(try r.ue("row_height_minus1", 0...(s.heightCtbs - 1)) + 1) }
                let lastW = s.widthCtbs - w.reduce(0, +), lastH = s.heightCtbs - h.reduce(0, +)
                guard lastW >= 1, lastH >= 1 else { throw r.fail("column_width_minus1", "tiles wider or taller than the picture") }
                p.tileColumnWidths = w + [lastW]
                p.tileRowHeights = h + [lastH]
            }
            p.loopFilterAcrossTiles = try r.flag("loop_filter_across_tiles_enabled_flag")
        }
        p.loopFilterAcrossSlices = try r.flag("pps_loop_filter_across_slices_enabled_flag")
        if try r.flag("deblocking_filter_control_present_flag") {
            p.deblockingFilterOverrideEnabled = try r.flag("deblocking_filter_override_enabled_flag")
            p.deblockingFilterDisabled = try r.flag("pps_deblocking_filter_disabled_flag")
            if !p.deblockingFilterDisabled {
                p.betaOffsetDiv2 = try r.se("pps_beta_offset_div2", -6...6)
                p.tcOffsetDiv2 = try r.se("pps_tc_offset_div2", -6...6)
            }
        }
        if try r.flag("pps_scaling_list_data_present_flag") { p.scalingList = try HEVCScalingList.parse(&r) }
        p.listsModificationPresent = try r.flag("lists_modification_present_flag")
        p.log2ParallelMergeLevel = try r.ue("log2_parallel_merge_level_minus2", 0...(s.log2CtbSize - 2)) + 2
        p.sliceSegmentHeaderExtensionPresent = try r.flag("slice_segment_header_extension_present_flag")
        if try r.flag("pps_extension_present_flag") {
            let range = try r.flag("pps_range_extension_flag")
            _ = try r.u(7, "pps_extension_flags")
            if range {
                if p.transformSkipEnabled { p.log2MaxTransformSkipSize = try r.ue("log2_max_transform_skip_block_size_minus2", 0...3) + 2 }
                p.crossComponentPrediction = try r.flag("cross_component_prediction_enabled_flag")
                p.chromaQpOffsetListEnabled = try r.flag("chroma_qp_offset_list_enabled_flag")
                // The rest (chroma QP offset lists, SAO offset scales) only matters with these
                // range-extension tools, which Main / Main10 streams do not use.
            }
        }
        return p
    }
}

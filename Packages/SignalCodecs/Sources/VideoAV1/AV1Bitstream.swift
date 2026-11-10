// AV1 (AV1 Bitstream & Decoding Process Specification, 2019 with errata) — the low-overhead
// OBU stream of a still image: OBU headers (5.3), the sequence header (5.5) and the
// uncompressed frame header of a shown key frame (5.9), with the descriptors of 4.10:
//   f(n)      n bits, MSB first        uvlc()   leading zeros, then that many bits
//   le(n)     n little-endian bytes    leb128() 7 bits per byte, ≤ 8 bytes
//   su(n)     n-bit two's complement   ns(n)    non-symmetric unsigned below n
// Only what a key frame needs is kept; inter-only syntax is parsed when it is present in a
// sequence header (it shapes the bit positions) and otherwise ignored.

import CodecCore

public enum AV1DecodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case limitExceeded(String)

    public var description: String {
        switch self {
        case .malformed(let s): "malformed AV1: \(s)"
        case .unsupported(let s): "unsupported AV1: \(s)"
        case .limitExceeded(let s): "AV1 limit: \(s)"
        }
    }
}

/// MSB-first reader with the AV1 descriptors.
struct AV1BitReader {
    let data: [UInt8]
    /// Bit position from the start of `data`.
    private(set) var position = 0
    let end: Int

    init(_ data: [UInt8], start: Int = 0, end: Int? = nil) {
        self.data = data
        self.position = start * 8
        self.end = (end ?? data.count) * 8
    }

    var bitsLeft: Int { end - position }
    var bytePosition: Int { position >> 3 }

    mutating func f(_ n: Int, _ what: @autoclosure () -> String = "") throws(AV1DecodeError) -> Int {
        guard n >= 0, n <= 32 else { throw .malformed("f(\(n))") }
        guard position + n <= end else { throw .malformed("bitstream ends inside \(what())") }
        var v = 0
        for _ in 0..<n {
            v = v << 1 | Int(data[position >> 3] >> (7 - UInt8(position & 7)) & 1)
            position += 1
        }
        return v
    }

    mutating func flag(_ what: @autoclosure () -> String = "") throws(AV1DecodeError) -> Bool { try f(1, what()) == 1 }

    mutating func su(_ n: Int, _ what: String = "") throws(AV1DecodeError) -> Int {
        var v = try f(n, what)
        let signMask = 1 << (n - 1)
        if v & signMask != 0 { v -= 2 * signMask }
        return v
    }

    mutating func ns(_ n: Int, _ what: String = "") throws(AV1DecodeError) -> Int {
        guard n > 1 else { return 0 }
        var w = 0, x = n
        while x != 0 { x >>= 1; w += 1 }
        let m = (1 << w) - n
        let v = try f(w - 1, what)
        if v < m { return v }
        let extra = try f(1, what)
        return (v << 1) - m + extra
    }

    mutating func le(_ n: Int, _ what: String = "") throws(AV1DecodeError) -> Int {
        var t = 0
        for i in 0..<n { t += try f(8, what) << (i * 8) }
        return t
    }

    mutating func uvlc(_ what: String = "") throws(AV1DecodeError) -> Int {
        var leadingZeros = 0
        while try f(1, what) == 0 {
            leadingZeros += 1
            guard leadingZeros < 32 else { throw .malformed("uvlc \(what)") }
        }
        if leadingZeros == 0 { return 0 }
        return try f(leadingZeros, what) + (1 << leadingZeros) - 1
    }

    mutating func leb128(_ what: String = "") throws(AV1DecodeError) -> Int {
        var value = 0
        for i in 0..<8 {
            let b = try f(8, what)
            value |= (b & 0x7F) << (i * 7)
            if b & 0x80 == 0 { return value }
        }
        throw .malformed("leb128 longer than 8 bytes")
    }

    mutating func byteAlign() { position = (position + 7) & ~7 }

    mutating func seek(bit: Int) { position = bit }
}

/// An OBU: its type and the byte range of its payload.
struct AV1OBU {
    var type: Int
    var temporalId: Int
    var spatialId: Int
    var hasExtension: Bool
    var payloadStart: Int
    var payloadEnd: Int
}

enum AV1OBUType {
    static let sequenceHeader = 1, temporalDelimiter = 2, frameHeader = 3, tileGroup = 4, metadata = 5, frame = 6
    static let redundantFrameHeader = 7, tileList = 8, padding = 15
}

extension AV1OBU {
    /// The OBUs of a low-overhead stream (every OBU carries obu_size).
    static func split(_ data: [UInt8], limit: Int = 4096) throws(AV1DecodeError) -> [AV1OBU] {
        var out: [AV1OBU] = []
        var r = AV1BitReader(data)
        while r.bitsLeft > 0 {
            guard r.bitsLeft >= 8 else { throw .malformed("stray bits after the last OBU") }
            guard try r.f(1, "obu_forbidden_bit") == 0 else { throw .malformed("obu_forbidden_bit") }
            let type = try r.f(4, "obu_type")
            let ext = try r.flag("obu_extension_flag")
            let hasSize = try r.flag("obu_has_size_field")
            _ = try r.f(1, "obu_reserved_1bit")
            var tid = 0, sid = 0
            if ext {
                tid = try r.f(3, "temporal_id")
                sid = try r.f(2, "spatial_id")
                _ = try r.f(3, "extension_header_reserved_3bits")
            }
            let size: Int
            if hasSize { size = try r.leb128("obu_size") } else { size = r.bitsLeft / 8 }
            let start = r.bytePosition
            guard size <= data.count - start else { throw .malformed("obu_size \(size) beyond the data") }
            out.append(AV1OBU(type: type, temporalId: tid, spatialId: sid, hasExtension: ext, payloadStart: start, payloadEnd: start + size))
            guard out.count <= limit else { throw .limitExceeded("more than \(limit) OBUs") }
            r.seek(bit: (start + size) * 8)
        }
        return out
    }
}

struct AV1SequenceHeader: Equatable {
    var profile = 0
    var stillPicture = false
    var reducedStillPictureHeader = false
    var timingInfoPresent = false
    var decoderModelInfoPresent = false
    var equalPictureInterval = false
    var bufferRemovalTimeLength = 0
    var framePresentationTimeLength = 0
    var operatingPointIdc: [Int] = [0]
    var decoderModelPresentForOp: [Bool] = [false]
    var frameWidthBits = 0, frameHeightBits = 0
    var maxFrameWidth = 0, maxFrameHeight = 0
    var frameIdNumbersPresent = false
    var deltaFrameIdLength = 0, additionalFrameIdLength = 0
    var use128 = false
    var enableFilterIntra = false
    var enableIntraEdgeFilter = false
    var enableOrderHint = false
    var orderHintBits = 0
    var seqForceScreenContentTools = 2
    var seqForceIntegerMv = 2
    var enableSuperres = false
    var enableCdef = false
    var enableRestoration = false
    // color_config
    var bitDepth = 8
    var monochrome = false
    var colorPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2
    var colorRange = false
    var subsamplingX = 1, subsamplingY = 1
    var separateUvDeltaQ = false
    var filmGrainParamsPresent = false

    var numPlanes: Int { monochrome ? 1 : 3 }

    static func parse(_ r: inout AV1BitReader) throws(AV1DecodeError) -> AV1SequenceHeader {
        var s = AV1SequenceHeader()
        s.profile = try r.f(3, "seq_profile")
        guard s.profile <= 2 else { throw .malformed("seq_profile \(s.profile)") }
        s.stillPicture = try r.flag()
        s.reducedStillPictureHeader = try r.flag()
        if s.reducedStillPictureHeader {
            _ = try r.f(5, "seq_level_idx")
        } else {
            s.timingInfoPresent = try r.flag("timing_info_present_flag")
            if s.timingInfoPresent {
                _ = try r.f(32, "num_units_in_display_tick")
                _ = try r.f(32, "time_scale")
                s.equalPictureInterval = try r.flag("equal_picture_interval")
                if s.equalPictureInterval { _ = try r.uvlc("num_ticks_per_picture_minus_1") }
                s.decoderModelInfoPresent = try r.flag("decoder_model_info_present_flag")
                if s.decoderModelInfoPresent {
                    s.bufferRemovalTimeLength = 0
                    let bufferDelayLength = try r.f(5, "buffer_delay_length_minus_1") + 1
                    _ = try r.f(32, "num_units_in_decoding_tick")
                    s.bufferRemovalTimeLength = try r.f(5) + 1
                    s.framePresentationTimeLength = try r.f(5) + 1
                    s.bufferDelayLength = bufferDelayLength
                }
            }
            let initialDisplayDelayPresent = try r.flag("initial_display_delay_present_flag")
            let count = try r.f(5, "operating_points_cnt_minus_1") + 1
            s.operatingPointIdc = []
            s.decoderModelPresentForOp = []
            for _ in 0..<count {
                s.operatingPointIdc.append(try r.f(12, "operating_point_idc"))
                let level = try r.f(5, "seq_level_idx")
                if level > 7 { _ = try r.f(1, "seq_tier") }
                var present = false
                if s.decoderModelInfoPresent {
                    present = try r.flag("decoder_model_present_for_this_op")
                    if present {
                        _ = try r.f(s.bufferDelayLength, "decoder_buffer_delay")
                        _ = try r.f(s.bufferDelayLength, "encoder_buffer_delay")
                        _ = try r.f(1, "low_delay_mode_flag")
                    }
                }
                s.decoderModelPresentForOp.append(present)
                if initialDisplayDelayPresent, try r.flag("initial_display_delay_present_for_this_op") { _ = try r.f(4) }
            }
        }
        s.frameWidthBits = try r.f(4) + 1
        s.frameHeightBits = try r.f(4) + 1
        s.maxFrameWidth = try r.f(s.frameWidthBits, "max_frame_width_minus_1") + 1
        s.maxFrameHeight = try r.f(s.frameHeightBits, "max_frame_height_minus_1") + 1
        if !s.reducedStillPictureHeader { s.frameIdNumbersPresent = try r.flag() }
        if s.frameIdNumbersPresent {
            s.deltaFrameIdLength = try r.f(4) + 2
            s.additionalFrameIdLength = try r.f(3) + 1
        }
        s.use128 = try r.flag("use_128x128_superblock")
        s.enableFilterIntra = try r.flag()
        s.enableIntraEdgeFilter = try r.flag()
        if !s.reducedStillPictureHeader {
            _ = try r.f(4, "enable_interintra_compound … enable_dual_filter")
            s.enableOrderHint = try r.flag("enable_order_hint")
            if s.enableOrderHint { _ = try r.f(2, "enable_jnt_comp, enable_ref_frame_mvs") }
            if try r.flag("seq_choose_screen_content_tools") {
                s.seqForceScreenContentTools = 2
            } else {
                s.seqForceScreenContentTools = try r.f(1)
            }
            if s.seqForceScreenContentTools > 0 {
                if try r.flag("seq_choose_integer_mv") { s.seqForceIntegerMv = 2 } else { s.seqForceIntegerMv = try r.f(1) }
            } else {
                s.seqForceIntegerMv = 2
            }
            if s.enableOrderHint { s.orderHintBits = try r.f(3) + 1 }
        }
        s.enableSuperres = try r.flag()
        s.enableCdef = try r.flag()
        s.enableRestoration = try r.flag()
        // color_config( )
        let highBitDepth = try r.flag("high_bitdepth")
        if s.profile == 2 && highBitDepth {
            s.bitDepth = try r.flag("twelve_bit") ? 12 : 10
        } else {
            s.bitDepth = highBitDepth ? 10 : 8
        }
        s.monochrome = s.profile == 1 ? false : try r.flag("mono_chrome")
        if try r.flag("color_description_present_flag") {
            s.colorPrimaries = try r.f(8)
            s.transferCharacteristics = try r.f(8)
            s.matrixCoefficients = try r.f(8)
        }
        if s.monochrome {
            s.colorRange = try r.flag("color_range")
            s.subsamplingX = 1
            s.subsamplingY = 1
            s.separateUvDeltaQ = false
        } else {
            if s.colorPrimaries == 1 && s.transferCharacteristics == 13 && s.matrixCoefficients == 0 {
                s.colorRange = true
                s.subsamplingX = 0
                s.subsamplingY = 0
            } else {
                s.colorRange = try r.flag("color_range")
                switch s.profile {
                case 0: s.subsamplingX = 1; s.subsamplingY = 1
                case 1: s.subsamplingX = 0; s.subsamplingY = 0
                default:
                    if s.bitDepth == 12 {
                        s.subsamplingX = try r.f(1)
                        s.subsamplingY = s.subsamplingX == 1 ? try r.f(1) : 0
                    } else {
                        s.subsamplingX = 1
                        s.subsamplingY = 0
                    }
                }
                if s.subsamplingX == 1 && s.subsamplingY == 1 { _ = try r.f(2, "chroma_sample_position") }
            }
            s.separateUvDeltaQ = try r.flag("separate_uv_delta_q")
        }
        s.filmGrainParamsPresent = try r.flag("film_grain_params_present")
        return s
    }

    var bufferDelayLength = 0
}

struct AV1FilmGrainParams: Equatable {
    var applyGrain = false
    var grainSeed = 0
    var pointY: [(value: Int, scaling: Int)] = []
    var chromaScalingFromLuma = false
    var pointCb: [(value: Int, scaling: Int)] = []
    var pointCr: [(value: Int, scaling: Int)] = []
    var grainScalingMinus8 = 0
    var arCoeffLag = 0
    var arCoeffsY: [Int] = [], arCoeffsCb: [Int] = [], arCoeffsCr: [Int] = []
    var arCoeffShiftMinus6 = 0
    var grainScaleShift = 0
    var cbMult = 0, cbLumaMult = 0, cbOffset = 0
    var crMult = 0, crLumaMult = 0, crOffset = 0
    var overlapFlag = false
    var clipToRestrictedRange = false

    static func == (a: AV1FilmGrainParams, b: AV1FilmGrainParams) -> Bool {
        a.applyGrain == b.applyGrain && a.grainSeed == b.grainSeed && a.pointY.map(\.value) == b.pointY.map(\.value)
            && a.pointY.map(\.scaling) == b.pointY.map(\.scaling) && a.arCoeffsY == b.arCoeffsY
    }
}

struct AV1FrameHeader {
    var showFrame = true
    var disableCdfUpdate = false
    var allowScreenContentTools = false
    var forceIntegerMv = true
    var frameWidth = 0, frameHeight = 0
    var upscaledWidth = 0
    var renderWidth = 0, renderHeight = 0
    var useSuperres = false
    var superresDenom = 8
    var miCols = 0, miRows = 0
    var allowIntrabc = false
    var disableFrameEndUpdateCdf = true
    // tile_info
    var tileCols = 1, tileRows = 1, tileColsLog2 = 0, tileRowsLog2 = 0
    var miColStarts: [Int] = [], miRowStarts: [Int] = []
    var tileSizeBytes = 4
    // quantization_params
    var baseQIdx = 0
    var deltaQYDc = 0, deltaQUDc = 0, deltaQUAc = 0, deltaQVDc = 0, deltaQVAc = 0
    var usingQmatrix = false
    var qmY = 15, qmU = 15, qmV = 15
    // segmentation_params
    var segmentationEnabled = false
    var featureEnabled = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 8)
    var featureData = [[Int]](repeating: [Int](repeating: 0, count: 8), count: 8)
    var segIdPreSkip = false
    var lastActiveSegId = 0
    // delta_q / delta_lf
    var deltaQPresent = false, deltaQRes = 0
    var deltaLfPresent = false, deltaLfRes = 0, deltaLfMulti = false
    var losslessArray = [Bool](repeating: false, count: 8)
    var codedLossless = false, allLossless = false
    var segQMLevel = [[Int]](repeating: [Int](repeating: 15, count: 8), count: 3)
    // loop_filter_params
    var loopFilterLevel = [0, 0, 0, 0]
    var loopFilterSharpness = 0
    var loopFilterDeltaEnabled = true
    var loopFilterRefDeltas = [1, 0, 0, 0, -1, 0, -1, -1]
    var loopFilterModeDeltas = [0, 0]
    // cdef_params
    var cdefDamping = 3
    var cdefBits = 0
    var cdefYPri = [Int](repeating: 0, count: 8), cdefYSec = [Int](repeating: 0, count: 8)
    var cdefUVPri = [Int](repeating: 0, count: 8), cdefUVSec = [Int](repeating: 0, count: 8)
    // lr_params
    var frameRestorationType = [0, 0, 0]
    var loopRestorationSize = [256, 256, 256]
    var usesLr = false
    var txMode = 0
    var reducedTxSet = false
    var filmGrain = AV1FilmGrainParams()

    func segFeatureActive(_ segment: Int, _ feature: Int) -> Bool { segmentationEnabled && featureEnabled[segment][feature] }

    /// get_qindex (7.12.2).
    func qindex(ignoreDeltaQ: Bool, segment: Int, current: Int) -> Int {
        if segFeatureActive(segment, 0) {
            let data = featureData[segment][0]
            var q = baseQIdx + data
            if !ignoreDeltaQ && deltaQPresent { q = current + data }
            return min(max(q, 0), 255)
        }
        if !ignoreDeltaQ && deltaQPresent { return current }
        return baseQIdx
    }

    static let segmentationFeatureBits = [8, 6, 6, 6, 6, 3, 0, 0]
    static let segmentationFeatureSigned = [true, true, true, true, true, false, false, false]
    static let segmentationFeatureMax = [255, 63, 63, 63, 63, 7, 0, 0]

    /// uncompressed_header( ) for a shown key frame; anything else is refused.
    static func parse(_ r: inout AV1BitReader, _ s: AV1SequenceHeader, temporalId: Int, spatialId: Int) throws(AV1DecodeError) -> AV1FrameHeader {
        var h = AV1FrameHeader()
        let idLen = s.frameIdNumbersPresent ? s.additionalFrameIdLength + s.deltaFrameIdLength + 1 : 0
        var errorResilient = true
        var frameSizeOverride = false
        if !s.reducedStillPictureHeader {
            guard try !r.flag("show_existing_frame") else { throw .unsupported("show_existing_frame") }
            let frameType = try r.f(2, "frame_type")
            guard frameType == 0 else { throw .unsupported("frame_type \(frameType) (only key frames are decoded)") }
            h.showFrame = try r.flag("show_frame")
            guard h.showFrame else { throw .unsupported("a key frame that is not shown") }
            if s.decoderModelInfoPresent && !s.equalPictureInterval { _ = try r.f(s.framePresentationTimeLength, "frame_presentation_time") }
            errorResilient = true
        }
        _ = errorResilient
        h.disableCdfUpdate = try r.flag("disable_cdf_update")
        h.allowScreenContentTools = s.seqForceScreenContentTools == 2 ? try r.flag("allow_screen_content_tools") : s.seqForceScreenContentTools == 1
        if h.allowScreenContentTools && s.seqForceIntegerMv == 2 { _ = try r.f(1, "force_integer_mv") }
        h.forceIntegerMv = true
        if s.frameIdNumbersPresent { _ = try r.f(idLen, "current_frame_id") }
        if !s.reducedStillPictureHeader { frameSizeOverride = try r.flag("frame_size_override_flag") }
        _ = try r.f(s.orderHintBits, "order_hint")
        if s.decoderModelInfoPresent {
            if try r.flag("buffer_removal_time_present_flag") {
                for (op, idc) in s.operatingPointIdc.enumerated() where s.decoderModelPresentForOp[op] {
                    let inT = (idc >> temporalId) & 1 == 1, inS = (idc >> (spatialId + 8)) & 1 == 1
                    if idc == 0 || (inT && inS) { _ = try r.f(s.bufferRemovalTimeLength, "buffer_removal_time") }
                }
            }
        }
        // refresh_frame_flags = allFrames for a shown key frame.
        // frame_size( ), superres_params( ), compute_image_size( ), render_size( )
        if frameSizeOverride {
            h.frameWidth = try r.f(s.frameWidthBits, "frame_width_minus_1") + 1
            h.frameHeight = try r.f(s.frameHeightBits, "frame_height_minus_1") + 1
        } else {
            h.frameWidth = s.maxFrameWidth
            h.frameHeight = s.maxFrameHeight
        }
        guard h.frameWidth <= s.maxFrameWidth, h.frameHeight <= s.maxFrameHeight else { throw .malformed("frame larger than max_frame_*") }
        h.useSuperres = s.enableSuperres ? try r.flag("use_superres") : false
        h.superresDenom = h.useSuperres ? try r.f(3, "coded_denom") + 9 : 8
        h.upscaledWidth = h.frameWidth
        h.frameWidth = (h.upscaledWidth * 8 + h.superresDenom / 2) / h.superresDenom
        h.miCols = 2 * ((h.frameWidth + 7) >> 3)
        h.miRows = 2 * ((h.frameHeight + 7) >> 3)
        if try r.flag("render_and_frame_size_different") {
            h.renderWidth = try r.f(16) + 1
            h.renderHeight = try r.f(16) + 1
        } else {
            h.renderWidth = h.upscaledWidth
            h.renderHeight = h.frameHeight
        }
        if h.allowScreenContentTools && h.upscaledWidth == h.frameWidth { h.allowIntrabc = try r.flag("allow_intrabc") }
        h.disableFrameEndUpdateCdf = s.reducedStillPictureHeader || h.disableCdfUpdate ? true : try r.flag("disable_frame_end_update_cdf")
        try h.parseTileInfo(&r, s)
        try h.parseQuantization(&r, s)
        try h.parseSegmentation(&r)
        // delta_q_params( ), delta_lf_params( )
        if h.baseQIdx > 0 { h.deltaQPresent = try r.flag("delta_q_present") }
        if h.deltaQPresent { h.deltaQRes = try r.f(2, "delta_q_res") }
        if h.deltaQPresent {
            if !h.allowIntrabc { h.deltaLfPresent = try r.flag("delta_lf_present") }
            if h.deltaLfPresent {
                h.deltaLfRes = try r.f(2)
                h.deltaLfMulti = try r.flag()
            }
        }
        h.codedLossless = true
        for seg in 0..<8 {
            let q = h.qindex(ignoreDeltaQ: true, segment: seg, current: h.baseQIdx)
            h.losslessArray[seg] = q == 0 && h.deltaQYDc == 0 && h.deltaQUAc == 0 && h.deltaQUDc == 0 && h.deltaQVAc == 0 && h.deltaQVDc == 0
            if !h.losslessArray[seg] { h.codedLossless = false }
            if h.usingQmatrix {
                if h.losslessArray[seg] {
                    h.segQMLevel[0][seg] = 15; h.segQMLevel[1][seg] = 15; h.segQMLevel[2][seg] = 15
                } else {
                    h.segQMLevel[0][seg] = h.qmY; h.segQMLevel[1][seg] = h.qmU; h.segQMLevel[2][seg] = h.qmV
                }
            }
        }
        h.allLossless = h.codedLossless && h.frameWidth == h.upscaledWidth
        try h.parseLoopFilter(&r, s)
        try h.parseCdef(&r, s)
        try h.parseLr(&r, s)
        h.txMode = h.codedLossless ? 0 : (try r.flag("tx_mode_select") ? 2 : 1)
        // frame_reference_mode( ), skip_mode_params( ), allow_warped_motion: nothing for intra frames.
        h.reducedTxSet = try r.flag("reduced_tx_set")
        // global_motion_params( ): nothing for intra frames.
        try h.parseFilmGrain(&r, s)
        return h
    }

    mutating func parseTileInfo(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        func tileLog2(_ blk: Int, _ target: Int) -> Int {
            var k = 0
            while (blk << k) < target { k += 1 }
            return k
        }
        let sbCols = s.use128 ? (miCols + 31) >> 5 : (miCols + 15) >> 4
        let sbRows = s.use128 ? (miRows + 31) >> 5 : (miRows + 15) >> 4
        let sbShift = s.use128 ? 5 : 4
        let sbSize = sbShift + 2
        let maxTileWidthSb = 4096 >> sbSize
        var maxTileAreaSb = (4096 * 2304) >> (2 * sbSize)
        let minLog2TileCols = tileLog2(maxTileWidthSb, sbCols)
        let maxLog2TileCols = tileLog2(1, min(sbCols, 64))
        let maxLog2TileRows = tileLog2(1, min(sbRows, 64))
        let minLog2Tiles = max(minLog2TileCols, tileLog2(maxTileAreaSb, sbRows * sbCols))
        miColStarts = []
        miRowStarts = []
        if try r.flag("uniform_tile_spacing_flag") {
            tileColsLog2 = minLog2TileCols
            while tileColsLog2 < maxLog2TileCols, try r.flag("increment_tile_cols_log2") { tileColsLog2 += 1 }
            let tileWidthSb = (sbCols + (1 << tileColsLog2) - 1) >> tileColsLog2
            var start = 0
            while start < sbCols { miColStarts.append(start << sbShift); start += tileWidthSb }
            miColStarts.append(miCols)
            tileCols = miColStarts.count - 1
            let minLog2TileRows = max(minLog2Tiles - tileColsLog2, 0)
            tileRowsLog2 = minLog2TileRows
            while tileRowsLog2 < maxLog2TileRows, try r.flag("increment_tile_rows_log2") { tileRowsLog2 += 1 }
            let tileHeightSb = (sbRows + (1 << tileRowsLog2) - 1) >> tileRowsLog2
            start = 0
            while start < sbRows { miRowStarts.append(start << sbShift); start += tileHeightSb }
            miRowStarts.append(miRows)
            tileRows = miRowStarts.count - 1
        } else {
            var widestTileSb = 0, start = 0
            while start < sbCols {
                miColStarts.append(start << sbShift)
                let maxWidth = min(sbCols - start, maxTileWidthSb)
                let size = try r.ns(maxWidth, "width_in_sbs_minus_1") + 1
                widestTileSb = max(size, widestTileSb)
                start += size
                guard miColStarts.count <= 64 else { throw .malformed("more than 64 tile columns") }
            }
            miColStarts.append(miCols)
            tileCols = miColStarts.count - 1
            tileColsLog2 = tileLog2(1, tileCols)
            maxTileAreaSb = minLog2Tiles > 0 ? (sbRows * sbCols) >> (minLog2Tiles + 1) : sbRows * sbCols
            let maxTileHeightSb = max(maxTileAreaSb / widestTileSb, 1)
            start = 0
            while start < sbRows {
                miRowStarts.append(start << sbShift)
                let maxHeight = min(sbRows - start, maxTileHeightSb)
                start += try r.ns(maxHeight, "height_in_sbs_minus_1") + 1
                guard miRowStarts.count <= 64 else { throw .malformed("more than 64 tile rows") }
            }
            miRowStarts.append(miRows)
            tileRows = miRowStarts.count - 1
            tileRowsLog2 = tileLog2(1, tileRows)
        }
        if tileColsLog2 > 0 || tileRowsLog2 > 0 {
            _ = try r.f(tileRowsLog2 + tileColsLog2, "context_update_tile_id")
            tileSizeBytes = try r.f(2) + 1
        }
    }

    mutating func parseQuantization(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        func deltaQ() throws(AV1DecodeError) -> Int { try r.flag("delta_coded") ? try r.su(7, "delta_q") : 0 }
        baseQIdx = try r.f(8, "base_q_idx")
        deltaQYDc = try deltaQ()
        if s.numPlanes > 1 {
            let diffUvDelta = s.separateUvDeltaQ ? try r.flag("diff_uv_delta") : false
            deltaQUDc = try deltaQ()
            deltaQUAc = try deltaQ()
            if diffUvDelta {
                deltaQVDc = try deltaQ()
                deltaQVAc = try deltaQ()
            } else {
                deltaQVDc = deltaQUDc
                deltaQVAc = deltaQUAc
            }
        }
        usingQmatrix = try r.flag("using_qmatrix")
        if usingQmatrix {
            qmY = try r.f(4)
            qmU = try r.f(4)
            qmV = s.separateUvDeltaQ ? try r.f(4) : qmU
        }
    }

    mutating func parseSegmentation(_ r: inout AV1BitReader) throws(AV1DecodeError) {
        segmentationEnabled = try r.flag("segmentation_enabled")
        if segmentationEnabled {
            // primary_ref_frame is PRIMARY_REF_NONE: update_map = 1, update_data = 1.
            for i in 0..<8 {
                for j in 0..<8 {
                    let enabled = try r.flag("feature_enabled")
                    featureEnabled[i][j] = enabled
                    var v = 0
                    if enabled {
                        let bits = Self.segmentationFeatureBits[j], limit = Self.segmentationFeatureMax[j]
                        if Self.segmentationFeatureSigned[j] {
                            v = min(max(try r.su(1 + bits, "feature_value"), -limit), limit)
                        } else {
                            v = min(max(try r.f(bits, "feature_value"), 0), limit)
                        }
                    }
                    featureData[i][j] = v
                }
            }
        }
        segIdPreSkip = false
        lastActiveSegId = 0
        for i in 0..<8 {
            for j in 0..<8 where featureEnabled[i][j] {
                lastActiveSegId = i
                if j >= 5 { segIdPreSkip = true }
            }
        }
    }

    mutating func parseLoopFilter(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        if codedLossless || allowIntrabc { return }
        loopFilterLevel[0] = try r.f(6)
        loopFilterLevel[1] = try r.f(6)
        if s.numPlanes > 1, loopFilterLevel[0] != 0 || loopFilterLevel[1] != 0 {
            loopFilterLevel[2] = try r.f(6)
            loopFilterLevel[3] = try r.f(6)
        }
        loopFilterSharpness = try r.f(3)
        loopFilterDeltaEnabled = try r.flag()
        if loopFilterDeltaEnabled, try r.flag("loop_filter_delta_update") {
            for i in 0..<8 where try r.flag("update_ref_delta") { loopFilterRefDeltas[i] = try r.su(7) }
            for i in 0..<2 where try r.flag("update_mode_delta") { loopFilterModeDeltas[i] = try r.su(7) }
        }
    }

    mutating func parseCdef(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        if codedLossless || allowIntrabc || !s.enableCdef {
            cdefBits = 0
            cdefDamping = 3
            return
        }
        cdefDamping = try r.f(2) + 3
        cdefBits = try r.f(2)
        for i in 0..<(1 << cdefBits) {
            cdefYPri[i] = try r.f(4)
            cdefYSec[i] = try r.f(2)
            if cdefYSec[i] == 3 { cdefYSec[i] += 1 }
            if s.numPlanes > 1 {
                cdefUVPri[i] = try r.f(4)
                cdefUVSec[i] = try r.f(2)
                if cdefUVSec[i] == 3 { cdefUVSec[i] += 1 }
            }
        }
    }

    mutating func parseLr(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        if allLossless || allowIntrabc || !s.enableRestoration { return }
        let remap = [0, 3, 1, 2]
        var usesChromaLr = false
        for i in 0..<s.numPlanes {
            frameRestorationType[i] = remap[try r.f(2, "lr_type")]
            if frameRestorationType[i] != 0 {
                usesLr = true
                if i > 0 { usesChromaLr = true }
            }
        }
        if usesLr {
            var shift: Int
            if s.use128 {
                shift = try r.f(1) + 1
            } else {
                shift = try r.f(1)
                if shift != 0 { shift += try r.f(1) }
            }
            loopRestorationSize[0] = 256 >> (2 - shift)
            let uvShift = s.subsamplingX == 1 && s.subsamplingY == 1 && usesChromaLr ? try r.f(1) : 0
            loopRestorationSize[1] = loopRestorationSize[0] >> uvShift
            loopRestorationSize[2] = loopRestorationSize[0] >> uvShift
        }
    }

    mutating func parseFilmGrain(_ r: inout AV1BitReader, _ s: AV1SequenceHeader) throws(AV1DecodeError) {
        guard s.filmGrainParamsPresent, showFrame else { return }
        var g = AV1FilmGrainParams()
        g.applyGrain = try r.flag("apply_grain")
        guard g.applyGrain else { return }
        g.grainSeed = try r.f(16)
        // update_grain = 1 for key frames.
        let numY = try r.f(4, "num_y_points")
        guard numY <= 14 else { throw .malformed("num_y_points \(numY)") }
        for _ in 0..<numY { g.pointY.append((try r.f(8), try r.f(8))) }
        for i in 1..<max(1, g.pointY.count) where g.pointY[i].value <= g.pointY[i - 1].value { throw .malformed("point_y_value not increasing") }
        g.chromaScalingFromLuma = s.monochrome ? false : try r.flag("chroma_scaling_from_luma")
        if s.monochrome || g.chromaScalingFromLuma || (s.subsamplingX == 1 && s.subsamplingY == 1 && numY == 0) {
            // no chroma points
        } else {
            let numCb = try r.f(4)
            guard numCb <= 10 else { throw .malformed("num_cb_points") }
            for _ in 0..<numCb { g.pointCb.append((try r.f(8), try r.f(8))) }
            let numCr = try r.f(4)
            guard numCr <= 10 else { throw .malformed("num_cr_points") }
            for _ in 0..<numCr { g.pointCr.append((try r.f(8), try r.f(8))) }
            for i in 1..<max(1, g.pointCb.count) where g.pointCb[i].value <= g.pointCb[i - 1].value { throw .malformed("point_cb_value not increasing") }
            for i in 1..<max(1, g.pointCr.count) where g.pointCr[i].value <= g.pointCr[i - 1].value { throw .malformed("point_cr_value not increasing") }
        }
        g.grainScalingMinus8 = try r.f(2)
        g.arCoeffLag = try r.f(2)
        let numPosLuma = 2 * g.arCoeffLag * (g.arCoeffLag + 1)
        let numPosChroma = numY > 0 ? numPosLuma + 1 : numPosLuma
        if numY > 0 { for _ in 0..<numPosLuma { g.arCoeffsY.append(try r.f(8)) } }
        if g.chromaScalingFromLuma || !g.pointCb.isEmpty { for _ in 0..<numPosChroma { g.arCoeffsCb.append(try r.f(8)) } }
        if g.chromaScalingFromLuma || !g.pointCr.isEmpty { for _ in 0..<numPosChroma { g.arCoeffsCr.append(try r.f(8)) } }
        g.arCoeffShiftMinus6 = try r.f(2)
        g.grainScaleShift = try r.f(2)
        if !g.pointCb.isEmpty {
            g.cbMult = try r.f(8); g.cbLumaMult = try r.f(8); g.cbOffset = try r.f(9)
        }
        if !g.pointCr.isEmpty {
            g.crMult = try r.f(8); g.crLumaMult = try r.f(8); g.crOffset = try r.f(9)
        }
        g.overlapFlag = try r.flag()
        g.clipToRestrictedRange = try r.flag()
        filmGrain = g
    }
}

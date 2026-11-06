// H1: VPS/SPS/PPS and slice segment headers of the generated clips against ffmpeg's
// trace_headers goldens (Tools/gen-hevc-fixtures.sh).

import CodecCore
import ContainerMP4
import Foundation
import Testing
@testable import VideoHEVC

struct HEVCFixture {
    let name: String
    let file: MP4File
    let track: MP4Track
    let config: HEVCDecoderConfiguration
    let bytes: [UInt8]

    init(_ name: String) throws {
        self.name = name
        let url = name.hasPrefix("/") ? URL(fileURLWithPath: name)
            : try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Resources"))
        bytes = [UInt8](try Data(contentsOf: url))
        file = try MP4Demuxer.parse(bytes)
        track = try #require(file.videoTracks.first)
        guard case .hevc(_, _, _, let c)? = track.sampleEntries.first else { throw HarnessError("\(name): not hvc1") }
        config = c
    }

    func golden(_ ext: String) throws -> Data {
        if name.hasPrefix("/") { return try Data(contentsOf: URL(fileURLWithPath: String(name.dropLast(4)) + "." + ext)) }
        return try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")))
    }

    func samples() -> [[UInt8]] {
        track.samples.map { Array(bytes[$0.offset ..< $0.offset + $0.size]) }
    }
}

struct HarnessError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

@Suite struct HEVCHeaderTests {
    static let fixtures = ["intra8_nolf", "intra8", "intra10", "ipb8", "ipb10", "scaling8", "tiles8", "vt10", "intra10_nolf", "intra8big_nolf",
                           "lossless_nolf", "scaling_intra_nolf"]

    @Test func headersOfFile() throws {
        guard let path = ProcessInfo.processInfo.environment["HEVC_HEADERS"] else { return }
        try headersMatchFFmpeg(path)
    }

    @Test(arguments: fixtures) func headersMatchFFmpeg(_ name: String) throws {
        let f = try HEVCFixture(name)
        let golden = try #require(try JSONSerialization.jsonObject(with: f.golden("headers.json")) as? [String: Any])
        var spsById: [Int: HEVCSPS] = [:], ppsById: [Int: HEVCPPS] = [:]
        for nal in f.config.sequenceParameterSets {
            let u = try HEVCNALUnit.make(nal.copyBytes()[...])
            let s = try HEVCSPS.parse(u.rbsp)
            spsById[s.id] = s
        }
        for nal in f.config.pictureParameterSets {
            let u = try HEVCNALUnit.make(nal.copyBytes()[...])
            let p = try HEVCPPS.parse(u.rbsp, sps: spsById)
            ppsById[p.id] = p
        }
        let sps = try #require(spsById.values.first), pps = try #require(ppsById.values.first)
        let gs = try #require((golden["sps"] as? [[String: Int]])?.first), gp = try #require((golden["pps"] as? [[String: Int]])?.first)
        #expect(sps.width == gs["pic_width_in_luma_samples"] && sps.height == gs["pic_height_in_luma_samples"])
        #expect(sps.bitDepthLuma - 8 == gs["bit_depth_luma_minus8"] && sps.log2MaxPocLsb - 4 == gs["log2_max_pic_order_cnt_lsb_minus4"])
        #expect(sps.log2MinCbSize - 3 == gs["log2_min_luma_coding_block_size_minus3"])
        #expect(sps.log2CtbSize - sps.log2MinCbSize == gs["log2_diff_max_min_luma_coding_block_size"])
        #expect(sps.shortTermRPS.count == gs["num_short_term_ref_pic_sets"])
        #expect((sps.saoEnabled ? 1 : 0) == gs["sample_adaptive_offset_enabled_flag"] && (sps.ampEnabled ? 1 : 0) == gs["amp_enabled_flag"])
        #expect((sps.scalingListEnabled ? 1 : 0) == gs["scaling_list_enabled_flag"] && (sps.temporalMvpEnabled ? 1 : 0) == gs["sps_temporal_mvp_enabled_flag"])
        #expect(pps.initQp - 26 == gp["init_qp_minus26"] && (pps.entropyCodingSync ? 1 : 0) == gp["entropy_coding_sync_enabled_flag"])
        #expect((pps.tilesEnabled ? 1 : 0) == gp["tiles_enabled_flag"] && (pps.signDataHiding ? 1 : 0) == gp["sign_data_hiding_enabled_flag"])
        #expect((pps.cuQpDeltaEnabled ? 1 : 0) == gp["cu_qp_delta_enabled_flag"] && (pps.transformSkipEnabled ? 1 : 0) == gp["transform_skip_enabled_flag"])

        let expected = try #require(golden["slices"] as? [[String: Int]])
        var got: [(HEVCNALUnit, HEVCSliceHeader)] = []
        var previous: HEVCSliceHeader?
        for sample in f.samples() {
            for u in try HEVCNALUnit.units(sample: ByteSlice(sample), lengthSize: f.config.nalLengthSize) where u.isVCL {
                let h = try HEVCSliceHeader.parse(u.rbsp, nal: u, sps: spsById, pps: ppsById, inherit: previous)
                if !h.dependentSliceSegment { previous = h }
                got.append((u, h))
            }
        }
        if !name.hasPrefix("/") { #expect(got.count == expected.count) }
        for ((u, h), g) in zip(got, expected) {
            #expect(u.type == g["nal_unit_type"])
            #expect(h.type.rawValue == g["slice_type"])
            if let lsb = g["slice_pic_order_cnt_lsb"] { #expect(h.pocLsb == lsb) }
            #expect(h.qpDelta == g["slice_qp_delta"])
            if let n = g["num_entry_point_offsets"] { #expect(h.entryPointOffsets.count == n) }
            if let n = g["num_ref_idx_l0_active_minus1"] { #expect(h.numRefIdxActive[0] - 1 == n) }
            if let n = g["num_ref_idx_l1_active_minus1"] { #expect(h.numRefIdxActive[1] - 1 == n) }
            if let n = g["five_minus_max_num_merge_cand"] { #expect(5 - h.maxNumMergeCand == n) }
            if let n = g["collocated_ref_idx"] { #expect(h.collocatedRefIdx == n) }
            if let n = g["slice_sao_luma_flag"] { #expect((h.saoLuma ? 1 : 0) == n) }
            if let n = g["slice_temporal_mvp_enabled_flag"] { #expect((h.temporalMvpEnabled ? 1 : 0) == n) }
            if let n = g["luma_log2_weight_denom"] { #expect(h.predWeight?.lumaLog2Denom == n) }
            // ffmpeg's bit positions count from the NAL start (2-byte header included).
            if let a = g["data_offset_bits_at_least"] { #expect(h.dataOffset == (a + 1 + 7) / 8 - 2) }
        }
    }
}

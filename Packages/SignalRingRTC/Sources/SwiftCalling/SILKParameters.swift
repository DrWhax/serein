/***********************************************************************
Copyright (c) 2006-2011, Skype Limited. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
- Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
***********************************************************************/

// SILK speech parameter decoding, RFC 6716 section 4.2.7.
// Codebooks and reference algorithm attribution accompany SILKTables.swift.
import Foundation

extension OpusRangeDecoder {
    /// Select one symbol from a row of a normative, packed SILK codebook.
    mutating func silkSymbol(_ table: [UInt8], from offset: Int = 0, count: Int? = nil) throws -> Int {
        let end = offset + (count ?? table.count)
        guard offset >= 0, end <= table.count, offset < end else { throw OpusPacket.Failure.invalidPacket }
        return try Int(symbol(inverseCDF: table[offset..<end]))
    }
}

struct SILKParameters {
    let type: Int
    let offset: Int
    let gainIndices: [Int]
    let frequencies: [Int]
    let interpolation: Int
    let lags: [Int]
    let pitchTaps: [[Double]]
    let pitchScale: Double
    let seed: Int32

    struct EntropyHistory {
        var type = 0
        var lagIndex = 0
    }

    init(_ range: inout OpusRangeDecoder, kilohertz: Int, subframes: Int,
         active: Bool, conditional: Bool, omitPitchScale: Bool = false, history: inout EntropyHistory) throws {
        typealias T = SILKTables
        let flags = active ? try 2 + range.silkSymbol(T.type_offset_VAD_iCDF) : try range.silkSymbol(T.type_offset_no_VAD_iCDF)
        type = flags >> 1
        offset = flags & 1
        var gains: [Int] = []
        if !conditional {
            gains.append(try range.silkSymbol(T.gain_iCDF, from: type * 8, count: 8) * 8 + range.silkSymbol(T.uniform8_iCDF))
        }
        while gains.count < subframes { gains.append(try range.silkSymbol(T.delta_gain_iCDF)) }
        gainIndices = gains
        frequencies = try Self.frequencies(&range, wide: kilohertz == 16, voiced: type == 2)
        interpolation = subframes == 4 ? try range.silkSymbol(T.NLSF_interpolation_factor_iCDF) : 4
        if type == 2 {
            let delta = conditional && history.type == 2 ? try range.silkSymbol(T.pitch_delta_iCDF) : 0
            if delta != 0 {
                history.lagIndex += delta - 9
            } else {
                let low = kilohertz == 8 ? T.uniform4_iCDF : kilohertz == 12 ? T.uniform6_iCDF : T.uniform8_iCDF
                history.lagIndex = try range.silkSymbol(T.pitch_lag_iCDF) * (kilohertz / 2) + range.silkSymbol(low)
            }
            let narrow = kilohertz == 8
            let contour: [UInt8]
            let offsets: [Int8]
            if subframes == 2 {
                contour = narrow ? T.pitch_contour_10_ms_NB_iCDF : T.pitch_contour_10_ms_iCDF
                offsets = narrow ? T.CB_lags_stage2_10_ms : T.CB_lags_stage3_10_ms
            } else {
                contour = narrow ? T.pitch_contour_NB_iCDF : T.pitch_contour_iCDF
                offsets = narrow ? T.CB_lags_stage2 : T.CB_lags_stage3
            }
            let index = try range.silkSymbol(contour)
            let lag = kilohertz * 2 + history.lagIndex
            lags = (0..<subframes).map { min(18 * kilohertz, max(2 * kilohertz, lag + Int(offsets[$0 * contour.count + index]))) }
            let period = try range.silkSymbol(T.LTP_per_index_iCDF)
            let distribution = [T.LTP_gain_iCDF_0, T.LTP_gain_iCDF_1, T.LTP_gain_iCDF_2][period]
            let codebook = [T.LTP_gain_vq_0, T.LTP_gain_vq_1, T.LTP_gain_vq_2][period]
            var taps: [[Double]] = []
            for _ in 0..<subframes {
                let start = try range.silkSymbol(distribution) * 5
                taps.append(codebook[start..<start+5].map { Double($0) / 128 })
            }
            pitchTaps = taps
            let scale = conditional || omitPitchScale ? 0 : try range.silkSymbol(T.LTPscale_iCDF)
            pitchScale = Double(T.LTPScales_table_Q14[scale]) / 16_384
        } else {
            lags = []
            pitchTaps = []
            pitchScale = 0
        }
        history.type = type
        seed = try Int32(range.silkSymbol(T.uniform4_iCDF))
    }

    private static func frequencies(_ range: inout OpusRangeDecoder, wide: Bool, voiced: Bool) throws -> [Int] {
        typealias T = SILKTables
        let order = wide ? 16 : 10
        let vector = try range.silkSymbol(wide ? T.NLSF_CB1_iCDF_WB : T.NLSF_CB1_iCDF_NB_MB,
                                          from: voiced ? 32 : 0, count: 32)
        let selection = wide ? T.NLSF_CB2_SELECT_WB : T.NLSF_CB2_SELECT_NB_MB
        let prediction = wide ? T.NLSF_PRED_WB_Q8 : T.NLSF_PRED_NB_MB_Q8
        let residualCDF = wide ? T.NLSF_CB2_iCDF_WB : T.NLSF_CB2_iCDF_NB_MB
        let weights = wide ? T.NLSF_CB1_WB_Wght_Q9 : T.NLSF_CB1_Wght_Q9
        let base = wide ? T.NLSF_CB1_WB_Q8 : T.NLSF_CB1_NB_MB_Q8
        var predictors = [Int](repeating: 0, count: order)
        var residuals = predictors
        for i in 0..<order {
            let bits = Int(selection[(vector * order + i) / 2]) >> (4 * (i % 2))
            // The unused last predictor is implicitly zero (the next residual starts at zero).
            if i < order - 1 {
                predictors[i] = Int(prediction[i + (bits & 1) * (order - 1)])
            }
            var residual = try range.silkSymbol(residualCDF, from: 9 * ((bits >> 1) & 7), count: 9) - 4
            if abs(residual) == 4 { residual += try residual.signum() * range.silkSymbol(T.NLSF_EXT_iCDF) }
            residuals[i] = residual
        }
        let step = wide ? 9830 : 11796
        var previous = 0
        var values = [Int](repeating: 0, count: order)
        for i in (0..<order).reversed() {
            let level = residuals[i]
            previous = ((previous * predictors[i]) >> 8) + (((level * 1024 - level.signum() * 102) * step) >> 16)
            let index = vector * order + i
            values[i] = max(0, min(32767, Int(base[index]) * 128 + (previous << 14) / Int(weights[index])))
        }
        stabilize(&values, distances: (wide ? T.NLSF_DELTA_MIN_WB_Q15 : T.NLSF_DELTA_MIN_NB_MB_Q15).map(Int.init))
        return values
    }

    private static func stabilize(_ values: inout [Int], distances: [Int]) {
        let order = values.count
        for _ in 0..<20 {
            var worst = 0
            var difference = values[0] - distances[0]
            for i in 1...order {
                let next = i == order ? 32768 : values[i]
                let gap = next - values[i-1] - distances[i]
                if gap < difference { difference = gap; worst = i }
            }
            guard difference < 0 else { return }
            if worst == 0 { values[0] = distances[0] }
            else if worst == order { values[order-1] = 32768 - distances[order] }
            else {
                let half = distances[worst] / 2
                let minimum = distances[..<worst].reduce(half, +)
                let maximum = 32768 - distances[(worst+1)...].reduce(half, +)
                let center = min(maximum, max(minimum, (values[worst-1] + values[worst] + 1) / 2))
                values[worst-1] = center - half
                values[worst] = center - half + distances[worst]
            }
        }
        values.sort()
        values[0] = max(values[0], distances[0])
        for i in 1..<order { values[i] = max(values[i], values[i-1] + distances[i]) }
        values[order-1] = min(values[order-1], 32768 - distances[order])
        for i in (0..<(order-1)).reversed() { values[i] = min(values[i], values[i+1] - distances[i+1]) }
    }
}

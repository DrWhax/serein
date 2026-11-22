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

import CodecCore
import Foundation

/// Mono playout for SILK, hybrid and CELT Opus. Keep all predictors transactional across
/// multiframe packets, so a malformed later frame cannot partially advance a call's decoder.
struct OpusSpeechDecoder {
    private var rate = 0
    private var synthesis = SILKSynthesis()
    private var resampler = SILKResampler()
    private var celt = CELTDecoder()
    private var previousMode: OpusPacket.Mode?
    private var previousRedundancy = false
    private var lastPCM: [Int16] = []
    private var lossGain = 1.0
    private(set) var recoveredIntervals: [Range<Int>] = []
    private(set) var finalRange: UInt32 = 0

    mutating func decode(_ packet: OpusPacket) throws -> [Int16] {
        var next = self, output: [Int16] = []
        output.reserveCapacity(packet.sampleCount)
        for frame in packet.frames { output += try next.decode(frame, packet: packet) }
        self = next
        return output
    }

    private mutating func decode(_ bytes: ByteSlice, packet: OpusPacket) throws -> [Int16] {
        let ticks = packet.samplesPerFrame
        if bytes.count <= 1 {
            finalRange = 0
            return conceal(samples: ticks)
        }
        var range = try OpusRangeDecoder(bytes)
        var pcm = [Int16](repeating: 0, count: ticks)
        if packet.mode != .celt {
            let khz = [8, 12, 16, 16][Int(packet.configuration / 4)]
            if khz != rate || previousMode == .celt {
                synthesis = SILKSynthesis()
                resampler = SILKResampler()
                rate = khz
            }
            let silk = try decodeSILK(&range, ticks: ticks, stereo: packet.stereo)
            pcm.removeAll(keepingCapacity: true)
            resampler.append(silk, kilohertz: khz, to: &pcm)
        }
        var extra: ByteSlice?, toSILK = false
        if packet.mode != .celt, range.bitsUsed + (packet.mode == .hybrid ? 37 : 17) <= bytes.count * 8,
           try packet.mode == .silk || range.bit(logProbability: 12) != 0 {
            toSILK = try range.bit(logProbability: 1) != 0
            let count = packet.mode == .hybrid ? Int(try range.uniform(below: 256)) + 2 : bytes.count - (range.bitsUsed + 7) / 8
            try range.removeRedundancy(count)
            extra = ByteSlice(Array(bytes.copyBytes().suffix(count)))
        }
        let endBandConfig: UInt8 = switch packet.configuration {
        case 0..<4: 17
        case 4..<12: 21
        case 12..<14: 25
        default: 29
        }
        var redRange: UInt32 = 0
        var redundant: [Int16] = []
        if let extra, toSILK {
            var tail = try OpusRangeDecoder(extra)
            redundant = try celt.decode(config: endBandConfig, stereo: packet.stereo, bytes: extra.count, range: &tail)
            redRange = tail.range
        }
        if packet.mode != .silk {
            if let previousMode, previousMode != packet.mode, !previousRedundancy { celt = CELTDecoder() }
            let audio = try celt.decode(config: packet.configuration, stereo: packet.stereo,
                                        bytes: bytes.count - (extra?.count ?? 0), range: &range)
            for i in pcm.indices { pcm[i] = Int16(clamping: Int(pcm[i]) + Int(audio[i])) }
        } else if previousMode == .hybrid && !(extra != nil && toSILK && previousRedundancy) {
            var tail = try OpusRangeDecoder(ByteSlice([255, 255]))
            let fade = try celt.decode(config: 16, stereo: packet.stereo, bytes: 2, range: &tail)
            for i in fade.indices { pcm[i] = Int16(clamping: Int(pcm[i]) + Int(fade[i])) }
        }
        if let extra, !toSILK {
            celt = CELTDecoder()
            var tail = try OpusRangeDecoder(extra)
            redundant = try celt.decode(config: endBandConfig, stereo: packet.stereo, bytes: extra.count, range: &tail)
            redRange = tail.range
            for i in 0..<120 { pcm[ticks-120+i] = Self.fade(pcm[ticks-120+i], redundant[120+i], at: i) }
        } else if !redundant.isEmpty && (previousMode != .silk || previousRedundancy) {
            for i in 0..<120 { pcm[i] = redundant[i]; pcm[120+i] = Self.fade(redundant[120+i], pcm[120+i], at: i) }
        } else if extra == nil, let previousMode, (packet.mode == .celt) != (previousMode == .celt), !previousRedundancy {
            let length = min(240, ticks)
            let transition = conceal(samples: length)
            let skip = length - 120
            for i in 0..<skip { pcm[i] = transition[i] }
            for i in 0..<120 { pcm[skip+i] = Self.fade(transition[skip+i], pcm[skip+i], at: i) }
        }
        previousMode = packet.mode
        previousRedundancy = extra != nil && !toSILK
        finalRange = range.range ^ redRange
        lastPCM = Array(pcm.suffix(960))
        lossGain = 1
        return pcm
    }

    private static func fade(_ a: Int16, _ b: Int16, at i: Int) -> Int16 {
        let x = sin((Double(i) + 0.5) * .pi / 240)
        let window = sin(0.5 * .pi * x * x)
        return Int16(clamping: Int((Double(a) + (Double(b) - Double(a)) * window * window).rounded()))
    }

    mutating func conceal(samples: Int) -> [Int16] {
        guard (1...5760).contains(samples) else { return [] }
        if (previousMode == .silk || previousMode == .hybrid), rate > 0, samples.isMultiple(of: 480) {
            let band = synthesis.conceal(samples: samples * rate / 48, kilohertz: rate)
            var result: [Int16] = []
            resampler.append(band, kilohertz: rate, to: &result)
            if previousMode == .hybrid {
                let high = celt.conceal(samples: samples)
                for i in result.indices { result[i] = Int16(clamping: Int(result[i]) + Int(high[i])) }
            }
            return result
        }
        guard !lastPCM.isEmpty else { return [Int16](repeating: 0, count: samples) }
        return (0..<samples).map { i in
            lossGain *= 0.9999
            return Int16(Double(lastPCM[i % lastPCM.count]) * lossGain)
        }
    }

    /// RFC 6716 §4.2.5. The first Opus frame may carry SILK audio for the immediately
    /// preceding frame. Older missing samples are concealed. Commit only a valid frame.
    mutating func recover(before packet: OpusPacket, samples: Int) throws -> [Int16] {
        guard samples > 0, samples <= 5760, samples.isMultiple(of: 120) else { throw OpusPacket.Failure.invalidPacket }
        recoveredIntervals.removeAll(keepingCapacity: true)
        let ticks = packet.samplesPerFrame
        guard packet.mode != .celt, previousMode != .celt, samples >= ticks, let first = packet.frames.first, first.count > 1
        else { return conceal(samples: samples) }
        var next = self
        var output = samples > ticks ? next.conceal(samples: samples - ticks) : []
        let khz = [8, 12, 16, 16][Int(packet.configuration / 4)]
        if next.rate != khz {
            next.synthesis = SILKSynthesis()
            next.resampler = SILKResampler()
            next.rate = khz
        }
        var range = try OpusRangeDecoder(first)
        let speech = try next.decodeSILK(&range, ticks: ticks, stereo: packet.stereo, recover: true)
        let offset = output.count
        next.recoveredIntervals = next.recoveredIntervals.map { ($0.lowerBound+offset)..<($0.upperBound+offset) }
        next.resampler.append(speech, kilohertz: khz, to: &output)
        if packet.mode == .hybrid {
            let high = next.celt.conceal(samples: ticks)
            for i in high.indices { output[offset+i] = Int16(clamping: Int(output[offset+i]) + Int(high[i])) }
        }
        next.previousMode = packet.mode
        next.previousRedundancy = false
        next.lastPCM = Array(output.suffix(960))
        next.lossGain = 1
        self = next
        return output
    }

    private mutating func decodeSILK(_ range: inout OpusRangeDecoder, ticks: Int, stereo: Bool, recover: Bool = false) throws -> [Int16] {
        let blocks = max(1, ticks / 960)
        let subframes = ticks == 480 ? 2 : 4
        let samples = rate * 5 * subframes
        let channels = stereo ? 2 : 1
        var active = [[Bool]](), redundant = [Int](repeating: 0, count: channels)
        for channel in 0..<channels {
            active.append(try (0..<blocks).map { _ in try range.bit(logProbability: 1) != 0 })
            redundant[channel] = try Int(range.bit(logProbability: 1))
        }
        if blocks > 1 {
            for channel in 0..<channels where redundant[channel] != 0 {
                redundant[channel] = try range.silkSymbol(blocks == 2 ? SILKTables.LBRR_flags_2_iCDF : SILKTables.LBRR_flags_3_iCDF) + 1
            }
        }
        if recover {
            let length = ticks / blocks
            recoveredIntervals = (0..<blocks).compactMap { i in
                redundant[0] & (1 << i) != 0 ? (i*length)..<((i+1)*length) : nil
            }
        }
        var histories = [SILKParameters.EntropyHistory](repeating: .init(), count: channels)
        var recovered: [Int16] = []
        for index in 0..<blocks {
            let mask = 1 << index
            if recover && redundant[0] & mask == 0 {
                recovered += synthesis.conceal(samples: samples, kilohertz: rate)
            }
            for ch in 0..<channels where redundant[ch] & mask != 0 {
                if stereo && ch == 0 { _ = try Self.stereoHeader(&range, sideActive: redundant[1] & mask != 0) }
                let conditional = index > 0 && redundant[ch] & (mask >> 1) != 0
                let params = try SILKParameters(&range, kilohertz: rate, subframes: subframes, active: true,
                                                conditional: conditional, history: &histories[ch])
                let pulses = try SILKPulses.decode(&range, samples: samples, type: params.type, offset: params.offset)
                if recover && ch == 0 { recovered += synthesis.render(params, pulses: pulses, conditional: conditional) }
            }
        }
        if recover { return recovered }
        var pcm: [Int16] = [], previousMidOnly = false
        for index in 0..<blocks {
            let midOnly = stereo ? try Self.stereoHeader(&range, sideActive: active[1][index]) : true
            for ch in 0..<(midOnly ? 1 : channels) {
                let sideRestart = index > 0 && ch == 1 && previousMidOnly
                let conditional = index > 0 && !sideRestart
                let params = try SILKParameters(&range, kilohertz: rate, subframes: subframes, active: active[ch][index],
                                                conditional: conditional, omitPitchScale: sideRestart, history: &histories[ch])
                let pulses = try SILKPulses.decode(&range, samples: samples, type: params.type, offset: params.offset)
                // The mono API renders SILK's mid channel, exactly as libopus does when decoding
                // stereo into a one-channel output. Side information still shares the range coder.
                if ch == 0 { pcm += synthesis.render(params, pulses: pulses, conditional: conditional) }
            }
            previousMidOnly = midOnly
        }
        return pcm
    }

    private static func stereoHeader(_ range: inout OpusRangeDecoder, sideActive: Bool) throws -> Bool {
        _ = try range.silkSymbol([249,247,246,245,244,234,210,202,201,200,197,174,82,59,56,55,54,46,22,12,11,10,9,7,0])
        for _ in 0..<2 {
            _ = try range.silkSymbol([171,85,0])
            _ = try range.silkSymbol([205,154,102,51,0])
        }
        return sideActive ? false : try range.silkSymbol([64,0]) != 0
    }
}

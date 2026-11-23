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

// SILK shell code, magnitudes and signs, RFC 6716 section 4.2.7.8.
// Reference algorithm attribution accompanies SILKTables.swift.
enum SILKPulses {
    static func decode(_ range: inout OpusRangeDecoder, samples: Int, type: Int, offset: Int) throws -> [Int] {
        typealias T = SILKTables
        let level = try range.silkSymbol(T.rate_levels_iCDF, from: (type >> 1) * 9, count: 9)
        let blocks = (samples + 15) / 16
        var sums = [Int](repeating: 0, count: blocks)
        var shifts = sums
        for i in 0..<blocks {
            var sum = try range.silkSymbol(T.pulses_per_block_iCDF, from: level * 18, count: 18)
            while sum == 17 {
                shifts[i] += 1
                let skip = shifts[i] == 10 ? 1 : 0
                sum = try range.silkSymbol(T.pulses_per_block_iCDF, from: 9 * 18 + skip, count: 18 - skip)
            }
            sums[i] = sum
        }

        var pulses = [Int](repeating: 0, count: blocks * 16)
        for i in 0..<blocks where sums[i] != 0 {
            try split(&range, total: sums[i], width: 16, start: i * 16, into: &pulses)
        }
        for i in 0..<blocks where shifts[i] != 0 {
            for k in i*16..<i*16+16 {
                for _ in 0..<shifts[i] {
                    pulses[k] = try 2 * pulses[k] + range.silkSymbol(T.lsb_iCDF)
                }
            }
        }
        let signTable = 7 * (offset + 2 * type)
        for i in 0..<blocks where sums[i] != 0 || shifts[i] != 0 {
            let cdf = [T.sign_iCDF[signTable + min(sums[i], 6)], 0]
            for k in i*16..<i*16+16 where pulses[k] != 0 {
                if try range.silkSymbol(cdf) == 0 { pulses[k] = -pulses[k] }
            }
        }
        pulses.removeLast(pulses.count - samples)
        return pulses
    }

    private static func split(_ range: inout OpusRangeDecoder, total: Int, width: Int,
                              start: Int, into pulses: inout [Int]) throws {
        guard total != 0 else { return }
        if width == 1 { pulses[start] = total; return }
        let table: [UInt8]
        switch width {
        case 2: table = SILKTables.shell_code_table0
        case 4: table = SILKTables.shell_code_table1
        case 8: table = SILKTables.shell_code_table2
        default: table = SILKTables.shell_code_table3
        }
        let left = try range.silkSymbol(table, from: Int(SILKTables.shell_code_table_offsets[total]), count: total + 1)
        let half = width / 2
        try split(&range, total: left, width: half, start: start, into: &pulses)
        try split(&range, total: total-left, width: half, start: start+half, into: &pulses)
    }
}

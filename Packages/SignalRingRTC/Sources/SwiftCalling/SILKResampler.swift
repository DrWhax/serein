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

// Decoder upsampling to 48 kHz. Coefficients from opus 1.5.2 silk/resampler_rom.c
// and silk/resampler_rom.h. See the redistribution notice in SILKTables.swift.
struct SILKResampler {
    private var states = [Int](repeating: 0, count: 6)
    private var tail = [Int](repeating: 0, count: 8)
    private var delayed: [Int16] = []
    private static let allpass = [1746, 14986, 39083, 6854, 25769, 55542]
    private static let fir = [
        [189, -600, 617, 30567], [117, -159, -1070, 29704], [52, 221, -2392, 28276],
        [-4, 529, -3350, 26341], [-48, 758, -3956, 23973], [-80, 905, -4235, 21254],
        [-99, 972, -4222, 18278], [-107, 967, -3957, 15143], [-103, 896, -3487, 11950],
        [-91, 773, -2865, 8798], [-71, 611, -2143, 5784], [-46, 425, -1375, 2996],
    ]

    mutating func append(_ samples: [Int16], kilohertz: Int, to output: inout [Int16]) {
        // SILK buffers one middle-channel sample before the delay compensation for each rate.
        let delay = 1 + (kilohertz == 16 ? 7 : kilohertz == 12 ? 4 : 0)
        if delayed.isEmpty { delayed = [Int16](repeating: 0, count: delay) }
        let input = delayed + samples
        delayed = Array(input.suffix(delay))

        var doubled = tail
        doubled.reserveCapacity(8 + 2 * samples.count)
        for sample in input.prefix(samples.count) {
            for branch in [0, 3] {
                var signal = Int(sample) << 10
                for stage in branch..<branch+3 {
                    let difference = signal - states[stage]
                    let filtered = (difference * Self.allpass[stage]) >> 16
                    let next = states[stage] + filtered
                    states[stage] = signal + filtered
                    signal = next
                }
                doubled.append(Int(Int16(clamping: (signal + 512) >> 10)))
            }
        }
        let count = samples.count * (48 / kilohertz)
        for i in 0..<count {
            let position = i * (2 * kilohertz)
            let start = position / 48
            let phase = (position % 48) / 4
            var sum = 0
            for j in 0..<4 {
                sum += doubled[start+j] * Self.fir[phase][j]
                sum += doubled[start+7-j] * Self.fir[11-phase][j]
            }
            output.append(Int16(clamping: (sum + 16384) >> 15))
        }
        tail = Array(doubled.suffix(8))
    }
}

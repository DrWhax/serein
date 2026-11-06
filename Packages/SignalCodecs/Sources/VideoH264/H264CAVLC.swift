// CAVLC residual blocks (H.264 9.2): coeff_token (by nC), the levels with their adaptive
// suffix length, total_zeros and run_before. Tables from H264Tables (FFmpeg's layout:
// coeff_token symbol = TotalCoeff·4 + TrailingOnes).

import CodecCore

enum CAVLCTables {
    static let coeffToken: [PrefixCodeTable] = (0 ..< 4).map { t in
        let lens = Array(H264Tables.coeffTokenLength[t * 68 ..< t * 68 + 68])
        let codes = Array(H264Tables.coeffTokenCode[t * 68 ..< t * 68 + 68])
        return PrefixCodeTable(codes: codes, lengths: lens, rootBits: 8)
    }
    static let chromaDCCoeffToken = PrefixCodeTable(codes: H264Tables.chromaDCCoeffTokenCode, lengths: H264Tables.chromaDCCoeffTokenLength, rootBits: 8)
    /// By TotalCoeff 1…15 (index 0 unused).
    static let totalZeros: [PrefixCodeTable?] = [nil] + (0 ..< 15).map { i in
        PrefixCodeTable(codes: Array(H264Tables.totalZerosCode[i * 16 ..< i * 16 + 16]), lengths: Array(H264Tables.totalZerosLength[i * 16 ..< i * 16 + 16]), rootBits: 9)
    }
    static let chromaDCTotalZeros: [PrefixCodeTable?] = [nil] + (0 ..< 3).map { i in
        PrefixCodeTable(codes: Array(H264Tables.chromaDCTotalZerosCode[i * 4 ..< i * 4 + 4]), lengths: Array(H264Tables.chromaDCTotalZerosLength[i * 4 ..< i * 4 + 4]), rootBits: 3)
    }
    /// By zerosLeft 1…6, then ≥ 7 (index 7).
    static let runBefore: [PrefixCodeTable?] = [nil] + (0 ..< 7).map { i in
        PrefixCodeTable(codes: Array(H264Tables.runBeforeCode[i * 16 ..< i * 16 + 16]), lengths: Array(H264Tables.runBeforeLength[i * 16 ..< i * 16 + 16]), rootBits: 9)
    }
}

extension H264Reader {
    /// residual_block_cavlc(): coefficients into `coeff[first ..< first + maxNumCoeff]` in scan
    /// order (the caller maps scan → raster). nC: −1 for chroma DC. Returns TotalCoeff.
    mutating func residualBlockCAVLC(nC: Int, maxNumCoeff: Int, into coeff: inout [Int32], at first: Int) throws(ParseFailure) -> Int {
        let token: Int
        if nC == -1 {
            token = try CAVLCTables.chromaDCCoeffToken.decode(&r, "coeff_token")
        } else {
            let t = nC < 2 ? 0 : nC < 4 ? 1 : nC < 8 ? 2 : 3
            token = try CAVLCTables.coeffToken[t].decode(&r, "coeff_token")
        }
        let totalCoeff = token >> 2, trailingOnes = token & 3
        guard totalCoeff <= maxNumCoeff, trailingOnes <= totalCoeff else { throw fail("coeff_token", "\(totalCoeff) coefficients in a block of \(maxNumCoeff)") }
        if totalCoeff == 0 { return 0 }
        var level = [Int32](repeating: 0, count: 16)
        var suffixLength = totalCoeff > 10 && trailingOnes < 3 ? 1 : 0
        for i in 0 ..< totalCoeff {
            if i < trailingOnes {
                level[i] = try r.bit("trailing_ones_sign_flag") == 1 ? -1 : 1
                continue
            }
            var prefix = 0
            while try r.bit("level_prefix") == 0 {
                prefix += 1
                guard prefix <= 31 else { throw fail("level_prefix", "too long") }
            }
            var levelCode = min(15, prefix) << suffixLength
            let suffixSize = prefix == 14 && suffixLength == 0 ? 4 : prefix >= 15 ? prefix - 3 : suffixLength
            if suffixSize > 0 {
                guard suffixSize <= 28 else { throw fail("level_suffix", "too long") }
                levelCode += Int(try r.bits(suffixSize, "level_suffix"))
            }
            if prefix >= 15 && suffixLength == 0 { levelCode += 15 }
            if prefix >= 16 { levelCode += (1 << (prefix - 3)) - 4096 }
            if i == trailingOnes && trailingOnes < 3 { levelCode += 2 }
            let v = levelCode & 1 == 0 ? (levelCode + 2) >> 1 : (-levelCode - 1) >> 1
            guard abs(v) <= (1 << 15) else { throw fail("coeff_level", "\(v) out of range") }
            level[i] = Int32(v)
            if suffixLength == 0 { suffixLength = 1 }
            if abs(v) > (3 << (suffixLength - 1)) && suffixLength < 6 { suffixLength += 1 }
        }
        var zerosLeft = 0
        if totalCoeff < maxNumCoeff {
            if nC == -1 {
                zerosLeft = try CAVLCTables.chromaDCTotalZeros[totalCoeff]!.decode(&r, "total_zeros")
            } else {
                zerosLeft = try CAVLCTables.totalZeros[totalCoeff]!.decode(&r, "total_zeros")
            }
        }
        guard totalCoeff + zerosLeft <= maxNumCoeff else { throw fail("total_zeros", "\(zerosLeft) + \(totalCoeff) > \(maxNumCoeff)") }
        // Place from the highest-frequency coefficient down.
        var pos = totalCoeff + zerosLeft - 1
        for i in 0 ..< totalCoeff {
            coeff[first + pos] = level[i]
            if i == totalCoeff - 1 { break }
            var run = 0
            if zerosLeft > 0 {
                run = try CAVLCTables.runBefore[min(zerosLeft, 7)]!.decode(&r, "run_before")
                guard run <= zerosLeft else { throw fail("run_before", "\(run) > \(zerosLeft)") }
            }
            zerosLeft -= run
            pos -= run + 1
        }
        return totalCoeff
    }
}

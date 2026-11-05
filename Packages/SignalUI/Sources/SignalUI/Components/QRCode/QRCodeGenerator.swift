// Port of qrcode-generator 2.0.4 (Kazuhiko Arase, MIT), which upstream's BrandedQRCode uses:
// byte-mode data, the smallest type number that fits, and the mask pattern with the lowest
// "lost point" score, so the modules match upstream's exactly. Input is a string we build
// (the provisioning / username link), not untrusted data.

import Foundation

public struct QRCodeGenerator: Sendable {
    public enum ErrorCorrectionLevel: Int, Sendable {
        // QRErrorCorrectionLevel: the format-information bits.
        case L = 1, M = 0, Q = 3, H = 2
        /// Row offset in RS_BLOCK_TABLE (L, M, Q, H order).
        var tableOffset: Int {
            switch self {
            case .L: 0
            case .M: 1
            case .Q: 2
            case .H: 3
            }
        }
    }

    public let moduleCount: Int
    private let modules: [[Bool]]

    public func isDark(row: Int, col: Int) -> Bool { modules[row][col] }

    /// `qrcode(0, level); addData(bytes); make()`. Nil if the data exceeds type 40.
    public init?(bytes: [UInt8], level: ErrorCorrectionLevel) {
        guard let typeNumber = Self.typeNumber(for: bytes.count, level: level) else { return nil }
        let data = Self.createData(typeNumber: typeNumber, level: level, bytes: bytes)
        var best = 0
        var minLost = 0
        for mask in 0..<8 {
            let m = Self.make(typeNumber: typeNumber, level: level, data: data, test: true, mask: mask)
            let lost = Self.lostPoint(m)
            if mask == 0 || minLost > lost {
                minLost = lost
                best = mask
            }
        }
        let final = Self.make(typeNumber: typeNumber, level: level, data: data, test: false, mask: best)
        modules = final.map { $0.map { $0 ?? false } }
        moduleCount = final.count
    }

    /// `qrcode.stringToBytes` (default): each UTF-16 code unit & 0xff.
    public init?(string: String, level: ErrorCorrectionLevel) {
        self.init(bytes: string.utf16.map { UInt8(truncatingIfNeeded: $0) }, level: level)
    }

    // MARK: - Layout

    static func make(typeNumber: Int, level: ErrorCorrectionLevel, data: [Int], test: Bool, mask: Int) -> [[Bool?]] {
        let n = typeNumber * 4 + 17
        var m = [[Bool?]](repeating: [Bool?](repeating: nil, count: n), count: n)
        func probe(_ row: Int, _ col: Int) {
            for r in -1...7 where row + r > -1 && row + r < n {
                for c in -1...7 where col + c > -1 && col + c < n {
                    m[row + r][col + c] = ((0...6).contains(r) && (c == 0 || c == 6)) || ((0...6).contains(c) && (r == 0 || r == 6))
                        || ((2...4).contains(r) && (2...4).contains(c))
                }
            }
        }
        probe(0, 0)
        probe(n - 7, 0)
        probe(0, n - 7)
        // setupPositionAdjustPattern
        let pos = patternPosition[typeNumber - 1]
        for row in pos {
            for col in pos where m[row][col] == nil {
                for r in -2...2 {
                    for c in -2...2 { m[row + r][col + c] = r == -2 || r == 2 || c == -2 || c == 2 || (r == 0 && c == 0) }
                }
            }
        }
        // setupTimingPattern
        if n - 8 > 8 {
            for r in 8..<(n - 8) where m[r][6] == nil { m[r][6] = r % 2 == 0 }
            for c in 8..<(n - 8) where m[6][c] == nil { m[6][c] = c % 2 == 0 }
        }
        // setupTypeInfo
        let bits = bchTypeInfo((level.rawValue << 3) | mask)
        for i in 0..<15 {
            let mod = !test && ((bits >> i) & 1) == 1
            if i < 6 { m[i][8] = mod } else if i < 8 { m[i + 1][8] = mod } else { m[n - 15 + i][8] = mod }
        }
        for i in 0..<15 {
            let mod = !test && ((bits >> i) & 1) == 1
            if i < 8 { m[8][n - i - 1] = mod } else if i < 9 { m[8][15 - i - 1 + 1] = mod } else { m[8][15 - i - 1] = mod }
        }
        m[n - 8][8] = !test
        // setupTypeNumber
        if typeNumber >= 7 {
            let tbits = bchTypeNumber(typeNumber)
            for i in 0..<18 { m[i / 3][i % 3 + n - 8 - 3] = !test && ((tbits >> i) & 1) == 1 }
            for i in 0..<18 { m[i % 3 + n - 8 - 3][i / 3] = !test && ((tbits >> i) & 1) == 1 }
        }
        // mapData
        var inc = -1, row = n - 1, bitIndex = 7, byteIndex = 0
        var col = n - 1
        while col > 0 {
            if col == 6 { col -= 1 }
            while true {
                for c in 0..<2 where m[row][col - c] == nil {
                    var dark = byteIndex < data.count && ((data[byteIndex] >> bitIndex) & 1) == 1
                    if maskBit(mask, row, col - c) { dark.toggle() }
                    m[row][col - c] = dark
                    bitIndex -= 1
                    if bitIndex == -1 {
                        byteIndex += 1
                        bitIndex = 7
                    }
                }
                row += inc
                if row < 0 || n <= row {
                    row -= inc
                    inc = -inc
                    break
                }
            }
            col -= 2
        }
        return m
    }

    static func maskBit(_ mask: Int, _ i: Int, _ j: Int) -> Bool {
        switch mask {
        case 0: (i + j) % 2 == 0
        case 1: i % 2 == 0
        case 2: j % 3 == 0
        case 3: (i + j) % 3 == 0
        case 4: (i / 2 + j / 3) % 2 == 0
        case 5: (i * j) % 2 + (i * j) % 3 == 0
        case 6: ((i * j) % 2 + (i * j) % 3) % 2 == 0
        default: ((i * j) % 3 + (i + j) % 2) % 2 == 0
        }
    }

    // MARK: - BCH

    static func bchDigit(_ data: Int) -> Int {
        var d = data, digit = 0
        while d != 0 {
            digit += 1
            d >>= 1
        }
        return digit
    }

    static let g15 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | 1
    static let g18 = (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 5) | (1 << 2) | 1
    static let g15Mask = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1)

    static func bchTypeInfo(_ data: Int) -> Int {
        var d = data << 10
        while bchDigit(d) - bchDigit(g15) >= 0 { d ^= g15 << (bchDigit(d) - bchDigit(g15)) }
        return ((data << 10) | d) ^ g15Mask
    }

    static func bchTypeNumber(_ data: Int) -> Int {
        var d = data << 12
        while bchDigit(d) - bchDigit(g18) >= 0 { d ^= g18 << (bchDigit(d) - bchDigit(g18)) }
        return (data << 12) | d
    }

    // MARK: - Mask scoring (QRUtil.getLostPoint)

    static func lostPoint(_ m: [[Bool?]]) -> Int {
        let n = m.count
        func dark(_ r: Int, _ c: Int) -> Bool { m[r][c] ?? false }
        var lost = 0
        for row in 0..<n {
            for col in 0..<n {
                var same = 0
                let d = dark(row, col)
                for r in -1...1 where row + r >= 0 && row + r < n {
                    for c in -1...1 where col + c >= 0 && col + c < n && !(r == 0 && c == 0) {
                        if d == dark(row + r, col + c) { same += 1 }
                    }
                }
                if same > 5 { lost += 3 + same - 5 }
            }
        }
        for row in 0..<(n - 1) {
            for col in 0..<(n - 1) {
                let count = [dark(row, col), dark(row + 1, col), dark(row, col + 1), dark(row + 1, col + 1)].filter { $0 }.count
                if count == 0 || count == 4 { lost += 3 }
            }
        }
        let finder = [true, false, true, true, true, false, true]
        for row in 0..<n {
            for col in 0..<(n - 6) where (0..<7).allSatisfy({ dark(row, col + $0) == finder[$0] }) { lost += 40 }
        }
        for col in 0..<n {
            for row in 0..<(n - 6) where (0..<7).allSatisfy({ dark(row + $0, col) == finder[$0] }) { lost += 40 }
        }
        var darkCount = 0
        for row in 0..<n { for col in 0..<n where dark(row, col) { darkCount += 1 } }
        // ratio * 10 is fractional in JS; scaled ×1000 here to compare exactly as it does.
        return lost * 1000 + Int((abs(100 * Double(darkCount) / Double(n) / Double(n) - 50) / 5 * 10 * 1000).rounded())
    }

    // MARK: - Data

    static func rsBlocks(typeNumber: Int, level: ErrorCorrectionLevel) -> [(total: Int, data: Int)] {
        let row = rsBlockTable[(typeNumber - 1) * 4 + level.tableOffset]
        var blocks: [(Int, Int)] = []
        for i in stride(from: 0, to: row.count, by: 3) {
            for _ in 0..<row[i] { blocks.append((row[i + 1], row[i + 2])) }
        }
        return blocks
    }

    /// Byte mode: 4-bit mode, then the length in 8 (types 1–9) or 16 bits.
    static func lengthBits(_ typeNumber: Int) -> Int { typeNumber < 10 ? 8 : 16 }

    static func typeNumber(for count: Int, level: ErrorCorrectionLevel) -> Int? {
        for t in 1..<40 {
            let capacity = rsBlocks(typeNumber: t, level: level).reduce(0) { $0 + $1.data } * 8
            if 4 + lengthBits(t) + count * 8 <= capacity { return t }
        }
        // As upstream: type 40 is tried without a capacity check, then createData throws.
        let capacity = rsBlocks(typeNumber: 40, level: level).reduce(0) { $0 + $1.data } * 8
        return 4 + lengthBits(40) + count * 8 <= capacity ? 40 : nil
    }

    static func createData(typeNumber: Int, level: ErrorCorrectionLevel, bytes: [UInt8]) -> [Int] {
        let blocks = rsBlocks(typeNumber: typeNumber, level: level)
        var bits: [Bool] = []
        func put(_ num: Int, _ length: Int) { for i in 0..<length { bits.append(((num >> (length - i - 1)) & 1) == 1) } }
        put(4, 4)
        put(bytes.count, lengthBits(typeNumber))
        for b in bytes { put(Int(b), 8) }
        let totalData = blocks.reduce(0) { $0 + $1.data }
        if bits.count + 4 <= totalData * 8 { put(0, 4) }
        while bits.count % 8 != 0 { bits.append(false) }
        while bits.count < totalData * 8 {
            put(0xEC, 8)
            if bits.count >= totalData * 8 { break }
            put(0x11, 8)
        }
        var buffer: [Int] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            var byte = 0
            for j in 0..<8 { byte = (byte << 1) | (bits[i + j] ? 1 : 0) }
            buffer.append(byte)
        }
        // createBytes: interleave data, then error-correction codewords.
        var offset = 0
        var dc: [[Int]] = [], ec: [[Int]] = []
        for block in blocks {
            let d = Array(buffer[offset..<(offset + block.data)])
            offset += block.data
            let ecCount = block.total - block.data
            dc.append(d)
            ec.append(reedSolomon(d, ecCount))
        }
        var out: [Int] = []
        for i in 0..<(dc.map(\.count).max() ?? 0) { for r in dc.indices where i < dc[r].count { out.append(dc[r][i]) } }
        for i in 0..<(ec.map(\.count).max() ?? 0) { for r in ec.indices where i < ec[r].count { out.append(ec[r][i]) } }
        return out
    }

    // MARK: - GF(256) Reed–Solomon (QRMath, qrPolynomial)

    static let exp: [Int] = {
        var t = [Int](repeating: 0, count: 256)
        for i in 0..<8 { t[i] = 1 << i }
        for i in 8..<256 { t[i] = t[i - 4] ^ t[i - 5] ^ t[i - 6] ^ t[i - 8] }
        return t
    }()
    static let log: [Int] = {
        var t = [Int](repeating: 0, count: 256)
        for i in 0..<255 { t[exp[i]] = i }
        return t
    }()
    static func gexp(_ n: Int) -> Int { exp[((n % 255) + 255) % 255] }

    /// The remainder of data·x^ecCount by the generator ∏(x − α^i), ecCount coefficients.
    static func reedSolomon(_ data: [Int], _ ecCount: Int) -> [Int] {
        var gen = [1]
        for i in 0..<ecCount {
            var next = [Int](repeating: 0, count: gen.count + 1)
            for (j, g) in gen.enumerated() {
                next[j] ^= g
                if g != 0 { next[j + 1] ^= gexp(log[g] + i) }
            }
            gen = next
        }
        var rem = data + [Int](repeating: 0, count: ecCount)
        for i in 0..<data.count where rem[i] != 0 {
            let ratio = log[rem[i]]
            for (j, g) in gen.enumerated() where g != 0 { rem[i + j] ^= gexp(log[g] + ratio) }
        }
        return Array(rem[data.count...])
    }

    static let patternPosition: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58],
        [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86], [6, 34, 62, 90],
        [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102], [6, 28, 54, 80, 106], [6, 32, 58, 84, 110], [6, 30, 58, 86, 114],
        [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130], [6, 30, 56, 82, 108, 134],
        [6, 34, 60, 86, 112, 138], [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146], [6, 30, 54, 78, 102, 126, 150],
        [6, 24, 50, 76, 102, 128, 154], [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162], [6, 26, 54, 82, 110, 138, 166],
        [6, 30, 58, 86, 114, 142, 170],
    ]

    /// RS_BLOCK_TABLE: per type, rows for L, M, Q, H of (count, total, data) triples.
    static let rsBlockTable: [[Int]] = [
        [1, 26, 19],
        [1, 26, 16],
        [1, 26, 13],
        [1, 26, 9],
        [1, 44, 34],
        [1, 44, 28],
        [1, 44, 22],
        [1, 44, 16],
        [1, 70, 55],
        [1, 70, 44],
        [2, 35, 17],
        [2, 35, 13],
        [1, 100, 80],
        [2, 50, 32],
        [2, 50, 24],
        [4, 25, 9],
        [1, 134, 108],
        [2, 67, 43],
        [2, 33, 15, 2, 34, 16],
        [2, 33, 11, 2, 34, 12],
        [2, 86, 68],
        [4, 43, 27],
        [4, 43, 19],
        [4, 43, 15],
        [2, 98, 78],
        [4, 49, 31],
        [2, 32, 14, 4, 33, 15],
        [4, 39, 13, 1, 40, 14],
        [2, 121, 97],
        [2, 60, 38, 2, 61, 39],
        [4, 40, 18, 2, 41, 19],
        [4, 40, 14, 2, 41, 15],
        [2, 146, 116],
        [3, 58, 36, 2, 59, 37],
        [4, 36, 16, 4, 37, 17],
        [4, 36, 12, 4, 37, 13],
        [2, 86, 68, 2, 87, 69],
        [4, 69, 43, 1, 70, 44],
        [6, 43, 19, 2, 44, 20],
        [6, 43, 15, 2, 44, 16],
        [4, 101, 81],
        [1, 80, 50, 4, 81, 51],
        [4, 50, 22, 4, 51, 23],
        [3, 36, 12, 8, 37, 13],
        [2, 116, 92, 2, 117, 93],
        [6, 58, 36, 2, 59, 37],
        [4, 46, 20, 6, 47, 21],
        [7, 42, 14, 4, 43, 15],
        [4, 133, 107],
        [8, 59, 37, 1, 60, 38],
        [8, 44, 20, 4, 45, 21],
        [12, 33, 11, 4, 34, 12],
        [3, 145, 115, 1, 146, 116],
        [4, 64, 40, 5, 65, 41],
        [11, 36, 16, 5, 37, 17],
        [11, 36, 12, 5, 37, 13],
        [5, 109, 87, 1, 110, 88],
        [5, 65, 41, 5, 66, 42],
        [5, 54, 24, 7, 55, 25],
        [11, 36, 12, 7, 37, 13],
        [5, 122, 98, 1, 123, 99],
        [7, 73, 45, 3, 74, 46],
        [15, 43, 19, 2, 44, 20],
        [3, 45, 15, 13, 46, 16],
        [1, 135, 107, 5, 136, 108],
        [10, 74, 46, 1, 75, 47],
        [1, 50, 22, 15, 51, 23],
        [2, 42, 14, 17, 43, 15],
        [5, 150, 120, 1, 151, 121],
        [9, 69, 43, 4, 70, 44],
        [17, 50, 22, 1, 51, 23],
        [2, 42, 14, 19, 43, 15],
        [3, 141, 113, 4, 142, 114],
        [3, 70, 44, 11, 71, 45],
        [17, 47, 21, 4, 48, 22],
        [9, 39, 13, 16, 40, 14],
        [3, 135, 107, 5, 136, 108],
        [3, 67, 41, 13, 68, 42],
        [15, 54, 24, 5, 55, 25],
        [15, 43, 15, 10, 44, 16],
        [4, 144, 116, 4, 145, 117],
        [17, 68, 42],
        [17, 50, 22, 6, 51, 23],
        [19, 46, 16, 6, 47, 17],
        [2, 139, 111, 7, 140, 112],
        [17, 74, 46],
        [7, 54, 24, 16, 55, 25],
        [34, 37, 13],
        [4, 151, 121, 5, 152, 122],
        [4, 75, 47, 14, 76, 48],
        [11, 54, 24, 14, 55, 25],
        [16, 45, 15, 14, 46, 16],
        [6, 147, 117, 4, 148, 118],
        [6, 73, 45, 14, 74, 46],
        [11, 54, 24, 16, 55, 25],
        [30, 46, 16, 2, 47, 17],
        [8, 132, 106, 4, 133, 107],
        [8, 75, 47, 13, 76, 48],
        [7, 54, 24, 22, 55, 25],
        [22, 45, 15, 13, 46, 16],
        [10, 142, 114, 2, 143, 115],
        [19, 74, 46, 4, 75, 47],
        [28, 50, 22, 6, 51, 23],
        [33, 46, 16, 4, 47, 17],
        [8, 152, 122, 4, 153, 123],
        [22, 73, 45, 3, 74, 46],
        [8, 53, 23, 26, 54, 24],
        [12, 45, 15, 28, 46, 16],
        [3, 147, 117, 10, 148, 118],
        [3, 73, 45, 23, 74, 46],
        [4, 54, 24, 31, 55, 25],
        [11, 45, 15, 31, 46, 16],
        [7, 146, 116, 7, 147, 117],
        [21, 73, 45, 7, 74, 46],
        [1, 53, 23, 37, 54, 24],
        [19, 45, 15, 26, 46, 16],
        [5, 145, 115, 10, 146, 116],
        [19, 75, 47, 10, 76, 48],
        [15, 54, 24, 25, 55, 25],
        [23, 45, 15, 25, 46, 16],
        [13, 145, 115, 3, 146, 116],
        [2, 74, 46, 29, 75, 47],
        [42, 54, 24, 1, 55, 25],
        [23, 45, 15, 28, 46, 16],
        [17, 145, 115],
        [10, 74, 46, 23, 75, 47],
        [10, 54, 24, 35, 55, 25],
        [19, 45, 15, 35, 46, 16],
        [17, 145, 115, 1, 146, 116],
        [14, 74, 46, 21, 75, 47],
        [29, 54, 24, 19, 55, 25],
        [11, 45, 15, 46, 46, 16],
        [13, 145, 115, 6, 146, 116],
        [14, 74, 46, 23, 75, 47],
        [44, 54, 24, 7, 55, 25],
        [59, 46, 16, 1, 47, 17],
        [12, 151, 121, 7, 152, 122],
        [12, 75, 47, 26, 76, 48],
        [39, 54, 24, 14, 55, 25],
        [22, 45, 15, 41, 46, 16],
        [6, 151, 121, 14, 152, 122],
        [6, 75, 47, 34, 76, 48],
        [46, 54, 24, 10, 55, 25],
        [2, 45, 15, 64, 46, 16],
        [17, 152, 122, 4, 153, 123],
        [29, 74, 46, 14, 75, 47],
        [49, 54, 24, 10, 55, 25],
        [24, 45, 15, 46, 46, 16],
        [4, 152, 122, 18, 153, 123],
        [13, 74, 46, 32, 75, 47],
        [48, 54, 24, 14, 55, 25],
        [42, 45, 15, 32, 46, 16],
        [20, 147, 117, 4, 148, 118],
        [40, 75, 47, 7, 76, 48],
        [43, 54, 24, 22, 55, 25],
        [10, 45, 15, 67, 46, 16],
        [19, 148, 118, 6, 149, 119],
        [18, 75, 47, 31, 76, 48],
        [34, 54, 24, 34, 55, 25],
        [20, 45, 15, 61, 46, 16],
    ]
}

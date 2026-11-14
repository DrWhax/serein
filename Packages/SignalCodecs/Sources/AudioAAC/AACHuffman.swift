// Decoding tables for the scalefactor and spectral Huffman codes (14496-3 Tables 4.A.1–4.A.12),
// built from the generated code/length tables (CodecCore's PrefixCodeTable; lengths ≤ 19 bits).

import CodecCore

enum AACHuffman {
    /// Each spectral book's symbols unpacked: four values per symbol (pairs use the first two),
    /// unsigned books as magnitudes (14496-3 4.6.3.3: quads base 3, pairs base 9/8/13/17).
    static let unpacked: [[Int32]] = (1...11).map { cb in
        return (0..<AACTables.spectralBits[cb - 1].count).flatMap { idx -> [Int32] in
            switch cb {
            case 1, 2: [Int32(idx / 27 - 1), Int32(idx / 9 % 3 - 1), Int32(idx / 3 % 3 - 1), Int32(idx % 3 - 1)]
            case 3, 4: [Int32(idx / 27), Int32(idx / 9 % 3), Int32(idx / 3 % 3), Int32(idx % 3)]
            case 5, 6: [Int32(idx / 9 - 4), Int32(idx % 9 - 4), 0, 0]
            case 7, 8: [Int32(idx / 8), Int32(idx % 8), 0, 0]
            case 9, 10: [Int32(idx / 13), Int32(idx % 13), 0, 0]
            default: [Int32(idx / 17), Int32(idx % 17), 0, 0]
            }
        }
    }

    static let scalefactor = PrefixCodeTable(codes: AACTables.scalefactorCodes, lengths: AACTables.scalefactorBits)
    static let spectral: [PrefixCodeTable] = (0..<11).map {
        PrefixCodeTable(codes: AACTables.spectralCodes[$0].map(UInt32.init), lengths: AACTables.spectralBits[$0])
    }
}

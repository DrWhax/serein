// Decoding tables for the scalefactor and spectral Huffman codes (14496-3 Tables 4.A.1–4.A.12),
// built from the generated code/length tables (CodecCore's PrefixCodeTable; lengths ≤ 19 bits).

import CodecCore

enum AACHuffman {
    static let scalefactor = PrefixCodeTable(codes: AACTables.scalefactorCodes, lengths: AACTables.scalefactorBits)
    static let spectral: [PrefixCodeTable] = (0..<11).map {
        PrefixCodeTable(codes: AACTables.spectralCodes[$0].map(UInt32.init), lengths: AACTables.spectralBits[$0])
    }
}

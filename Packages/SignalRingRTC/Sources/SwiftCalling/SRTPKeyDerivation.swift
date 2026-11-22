import CryptoKit
import Foundation
import simd

/// AES-CM PRF for the GCM profiles, with a zero key derivation rate (RFC 3711/6188/7714).
/// Serein ships on Apple Silicon. The SDK exposes its AES rounds as by-value SIMD operations.
/// No lookup table is indexed by a secret. CryptoKit handles packet AEAD.
struct SRTPKeyDerivation {
    private let cipher: AESBlockCipher
    private let salt: SIMD16<UInt8>
    private let keyLength: Int

    init(key: SymmetricKey, salt: SymmetricKey) throws {
        guard key.bitCount == 128 || key.bitCount == 256, salt.bitCount == 96 else { throw CallingWireError.malformed }
        keyLength = key.bitCount / 8
        var iv = SIMD16<UInt8>()
        let saltBytes = salt.bytes
        for i in 0..<12 { iv[i] = saltBytes[i] }
        self.salt = iv

        cipher = try AESBlockCipher(key)
    }

    private func block(label: UInt8, counter: UInt8) -> SIMD16<UInt8> {
        var state = salt
        state[7] ^= label
        state[15] = counter
        return cipher.encrypt(state)
    }

    func sessionKeys(rtcp: Bool) -> SRTPKeys {
        let keyLabel: UInt8 = rtcp ? 3 : 0
        let first = block(label: keyLabel, counter: 0)
        var bytes = (0..<16).map { first[$0] }
        if keyLength == 32 {
            let second = block(label: keyLabel, counter: 1)
            bytes += (0..<16).map { second[$0] }
        }
        let saltBlock = block(label: keyLabel + 2, counter: 0)
        return SRTPKeys(key: SymmetricKey(data: bytes), salt: (0..<12).map { saltBlock[$0] })
    }
}

/// AES encryption for the calling protocols, using the Apple Silicon AES instructions.
struct AESBlockCipher {
    private let roundKeys: [SIMD16<UInt8>]

    init(_ key: SymmetricKey) throws {
        guard key.bitCount == 128 || key.bitCount == 256 else { throw CallingWireError.malformed }
        let nk = key.bitCount / 32
        let rounds = nk + 6
        let raw = key.bytes
        var words = (0..<nk).map { i in SIMD4<UInt8>(raw[i*4], raw[i*4+1], raw[i*4+2], raw[i*4+3]) }
        var rcon: UInt8 = 1
        for i in nk..<(4 * (rounds + 1)) {
            var word = words[i-1]
            if i.isMultiple(of: nk) {
                word = Self.subWord(SIMD4(word[1], word[2], word[3], word[0]))
                word[0] ^= rcon
                rcon = (rcon << 1) ^ (rcon >= 128 ? 0x1b : 0)
            } else if nk == 8 && i % nk == 4 {
                word = Self.subWord(word)
            }
            words.append(words[i-nk] ^ word)
        }
        roundKeys = (0...rounds).map { round in
            var vector = SIMD16<UInt8>()
            for i in 0..<16 { vector[i] = words[round*4+i/4][i%4] }
            return vector
        }
    }

    private static func subWord(_ word: SIMD4<UInt8>) -> SIMD4<UInt8> {
        // Four identical columns make the AES ShiftRows permutation a no-op.
        var repeated = SIMD16<UInt8>()
        for i in 0..<16 { repeated[i] = word[i % 4] }
        let substituted = vaeseq_u8(repeated, SIMD16<UInt8>())
        return SIMD4(substituted[0], substituted[1], substituted[2], substituted[3])
    }

    func encrypt(_ block: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var state = block
        let rounds = roundKeys.count - 1
        for i in 0..<(rounds - 1) { state = vaesmcq_u8(vaeseq_u8(state, roundKeys[i])) }
        return vaeseq_u8(state, roundKeys[rounds - 1]) ^ roundKeys[rounds]
    }

}

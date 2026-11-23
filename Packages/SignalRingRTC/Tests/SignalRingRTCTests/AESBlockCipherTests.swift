// Known answers for the AES block function on the Apple Silicon AES instructions
// (SRTPKeyDerivation.swift), which SRTP key derivation and group frame encryption use. The
// chained values were computed with OpenSSL AES-ECB and exercise 10,000 data-dependent blocks.

import CryptoKit
import Foundation
@testable import SwiftCalling
import Testing

@Suite struct AESBlockCipherTests {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = [], digits = Array(hex.utf8)
        while digits.count >= 2 {
            out.append(UInt8(String(decoding: digits.prefix(2), as: UTF8.self), radix: 16)!)
            digits.removeFirst(2)
        }
        return out
    }

    private func block(_ hex: String) -> SIMD16<UInt8> {
        let raw = bytes(hex)
        var value = SIMD16<UInt8>()
        for i in 0..<16 { value[i] = raw[i] }
        return value
    }

    @Test(arguments: [
        // FIPS-197 Appendix C.1 (AES-128) and C.3 (AES-256)
        ("000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a"),
        ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "00112233445566778899aabbccddeeff",
         "8ea2b7ca516745bfeafc49904b496089"),
        // FIPS-197 Appendix B
        ("2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32"),
        // NIST SP 800-38A F.1.1 and F.1.5 (ECB, first block)
        ("2b7e151628aed2a6abf7158809cf4f3c", "6bc1bee22e409f96e93d7e117393172a", "3ad77bb40d7a3660a89ecaf32466ef97"),
        ("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", "6bc1bee22e409f96e93d7e117393172a",
         "f3eed1bdb5d2a03c064b5a7e3db181f8"),
    ])
    func standardVectors(key: String, plaintext: String, ciphertext: String) throws {
        let cipher = try AESBlockCipher(SymmetricKey(data: bytes(key)))
        #expect(cipher.encrypt(block(plaintext)) == block(ciphertext))
    }

    @Test(arguments: [
        ("000102030405060708090a0b0c0d0e0f", "4a1f227d5d20b689bbd957ebd4a6c017"),
        ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8e88a264252d2587701f6843d8ffc064"),
    ])
    func tenThousandChainedBlocks(key: String, final: String) throws {
        let cipher = try AESBlockCipher(SymmetricKey(data: bytes(key)))
        var value = SIMD16<UInt8>()
        for _ in 0..<10_000 { value = cipher.encrypt(value) }
        #expect(value == block(final))
    }

    @Test func rejectsOtherKeySizes() {
        for size in [0, 15, 24, 31, 33] {
            #expect(throws: (any Error).self) { try AESBlockCipher(SymmetricKey(data: [UInt8](repeating: 1, count: size))) }
        }
    }
}

import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct SRTPTests {
    @Test func aesCounterKeyDerivation() throws {
        // AES-ECB reference encryption of RFC 3711/6188 counter blocks with OpenSSL.
        for (size, key, salt, controlKey, controlSalt) in [
            (16, "f6677c97f280c501bf7f3bd0eba0afa9", "b68aa981aabd8883d1a66112",
             "ac408cce982899ddda66c92c257474b6", "6de70f6bffafb6791a8e190a"),
            (32, "bddc4ccab15066ccc1fe6b0cba133eb6f4c2db1dc38805a37b92171c5d0a81cc", "915fa659b77a2a559ce0fec9",
             "f7f8403ba47ff5644c8d079e694c9e9e8941c9b796049151e061e0f77cd557f2", "37511821a7ce2d9ff7ee1514")
        ] {
            let kdf = try SRTPKeyDerivation(key: SymmetricKey(data: Data(0..<UInt8(size))), salt: SymmetricKey(data: Data(0..<12)))
            let rtp = kdf.sessionKeys(rtcp: false), rtcp = kdf.sessionKeys(rtcp: true)
            #expect(rtp.key == SymmetricKey(data: callingTestBytes(key)) && rtp.salt == callingTestBytes(salt))
            #expect(rtcp.key == SymmetricKey(data: callingTestBytes(controlKey)) && rtcp.salt == callingTestBytes(controlSalt))
        }
    }

    @Test func rfc7714AES256GCM() throws {
        let keys = SRTPKeys(key: SymmetricKey(data: Data(0..<32)), salt: Array("Quid pro quo".utf8))
        let sender = SRTPSender(keys: keys, ssrc: 0x5501a0b2, startingAt: 0xf17b)
        let receiver = SRTPReceiver(keys: keys, ssrc: 0x5501a0b2)
        let plain = Data("Gallia est omnis divisa in partes tres".utf8)
        let wire = Data(callingTestBytes("""
        8040f17b8041f8d35501a0b2
        32b1de78a822fe12ef9f78fa332e33aab18012389a58e2f3b50b2a0276ffae0f1ba63799b87b
        7aa3db36dfffd6b0f9bb7878d7a76c13
        """))
        #expect(try sender.seal(plain, type: 64, timestamp: 0x8041f8d3) == wire)
        #expect(try receiver.open(wire).bytes == plain)
        #expect(throws: SRTPError.self) { try receiver.open(wire) }
    }

    @Test func rfc7714EncryptedRTCP() throws {
        // RFC 7714 sections 17.1 and 17.2.
        let plain = Data(callingTestBytes("""
        81c8000d4d6172734e5450314e545032525450200000042a0000e9304c756e61
        deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
        """))
        for (size, hex) in [(16, """
            81c8000d4d61727363e94885dcdab67ca727d7662f6b7e997ff5c0f76c06f32d
            c676a5f1730d6fda4ce09b4686303ded0bb9275bc84aa45896cf4d2fc5abf87245d9eade800005d4
            """), (32, """
            81c8000d4d617273d50ae4d1f5ce5d304ba297e47d470c282c3ece5dbffe0a50
            a2eaa5c1110555be8415f658c61de0476f1b6fad1d1eb30c4446839f57ff6f6cb26ac3be800005d4
            """)] {
            let keys = SRTPKeys(key: SymmetricKey(data: Data(0..<UInt8(size))), salt: Array("Quid pro quo".utf8))
            let sender = SRTCPSender(keys: keys, ssrc: 0x4d617273, startingAt: 0x5d4)
            let receiver = SRTCPReceiver(keys: keys, ssrc: 0x4d617273)
            let wire = Data(callingTestBytes(hex))
            #expect(try sender.seal(plain) == wire)
            var damaged = wire
            damaged[damaged.endIndex - 1] ^= 1
            #expect(throws: (any Error).self) { try receiver.open(damaged) }
            #expect(try receiver.open(wire) == plain)
            #expect(throws: SRTPError.self) { try receiver.open(wire) }
            let last = SRTCPSender(keys: keys, ssrc: 0x4d617273, startingAt: 0x7fff_ffff)
            #expect(try receiver.open(last.seal(plain)) == plain)
            #expect(throws: SRTPError.self) { try last.seal(plain) }
        }
    }

    @Test func rolloverAndReplay() throws {
        let keys = SRTPKeys(key: SymmetricKey(size: .bits256), salt: Array(repeating: 17, count: 12))
        let sender = SRTPSender(keys: keys, ssrc: 13, startingAt: 65_534)
        let receiver = SRTPReceiver(keys: keys, ssrc: 13)
        let packets = try (0..<70).map { try sender.seal(Data([UInt8($0)]), type: 101, timestamp: UInt32($0)) }
        #expect(try receiver.open(packets[0]).bytes == Data([0]))
        var corrupted = packets[2]
        corrupted[corrupted.startIndex + 5] ^= 1
        #expect(throws: (any Error).self) { try receiver.open(corrupted) }
        #expect(try receiver.open(packets[2]).bytes == Data([2]))
        #expect(try receiver.open(packets[1]).bytes == Data([1]))
        #expect(throws: SRTPError.self) { try receiver.open(packets[1]) }
        #expect(try receiver.open(packets[69]).bytes == Data([69]))
        #expect(throws: SRTPError.self) { try receiver.open(packets[3]) }
    }
}

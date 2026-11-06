import Foundation
import LibSignalClient
import Testing
@testable import SignalCore
import SignalProtos

extension Data {
    init(hexString: String) {
        var out = Data()
        var it = hexString.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        self = out
    }
}

@Suite struct CryptoTests {
    // NIST SP 800-38A F.2.5 (CBC-AES256.Encrypt) and F.5.5 (CTR-AES256.Encrypt).
    let key = Data(hexString: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    let blocks = Data(hexString: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")

    @Test func aesCBCMatchesNIST() throws {
        let iv = Data(hexString: "000102030405060708090a0b0c0d0e0f")
        let c = try SignalCrypto.aes256CBCEncrypt(key: key, iv: iv, blocks)
        #expect(c.prefix(32).hex == "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d")
        #expect(c.count == 48)  // + one PKCS#7 padding block
        #expect(try SignalCrypto.aes256CBCDecrypt(key: key, iv: iv, c) == blocks)
        #expect(throws: (any Error).self) { try SignalCrypto.aes256CBCDecrypt(key: key, iv: iv, c.prefix(40)) }
    }

    @Test func aesCTRMatchesNIST() throws {
        let counter = Data(hexString: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let c = try SignalCrypto.aes256CTR(key: key, iv: counter, blocks)
        #expect(c.hex == "601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5")
        #expect(try SignalCrypto.aes256CTR(key: key, iv: counter, c) == blocks)
    }

    @Test func hmacMatchesRFC4231() {
        let mac = SignalCrypto.hmacSHA256(key: Data("Jefe".utf8), Data("what do ya want for nothing?".utf8))
        #expect(mac.hex == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func randomBytes() {
        let a = SignalCrypto.randomBytes(33), b = SignalCrypto.randomBytes(33)
        #expect(a.count == 33 && a != b)
    }

    @Test func provisioningRoundTripAndTamper() throws {
        let cipher = ProvisioningCipher()
        var m = Signalservice_ProvisionMessage()
        m.number = "+14155550100"
        m.provisioningCode = "123456"
        let env = try ProvisioningCipher.encrypt(m, to: cipher.publicKey)
        let back = try cipher.decrypt(envelope: env)
        #expect(back.number == m.number && back.provisioningCode == "123456")

        var tampered = try Signalservice_ProvisionEnvelope(serializedBytes: env)
        tampered.body[tampered.body.startIndex + 20] ^= 1
        #expect(throws: ProvisioningError.badMAC) { try cipher.decrypt(envelope: try tampered.serializedData()) }
        #expect(throws: ProvisioningError.self) { try ProvisioningCipher().decrypt(envelope: env) }
    }

    @Test func linkURLEscapesBase64() throws {
        let url = ProvisioningCipher().linkURL(address: "a+b/c=")
        #expect(url.hasPrefix("sgnl://linkdevice?uuid=a%2Bb%2Fc%3D&pub_key="))
        #expect(!url.contains("+") && url.hasSuffix("&capabilities=nopni%2Cnopni2"))
        let comps = URLComponents(string: url)!
        let pub = comps.queryItems!.first { $0.name == "pub_key" }!.value!
        #expect(try PublicKey(Data(base64Encoded: pub)!).serialize().count == 33)
    }

    @Test func deviceNameRoundTrip() throws {
        let identity = IdentityKeyPair.generate()
        let enc = try DeviceNameCipher.encrypt("Work Mac 💻", identityPublicKey: identity.publicKey)
        #expect(try DeviceNameCipher.decrypt(enc, identityPrivateKey: identity.privateKey) == "Work Mac 💻")
        #expect(throws: ProvisioningError.badMAC) { try DeviceNameCipher.decrypt(enc, identityPrivateKey: IdentityKeyPair.generate().privateKey) }
    }

    @Test func transportPadding() throws {
        #expect(try MessageReceiver.unpad(Data([1, 2, 0x80])) == Data([1, 2]))
        #expect(try MessageReceiver.unpad(Data([1, 2, 0x80, 0, 0, 0])) == Data([1, 2]))
        #expect(throws: ReceiveError.invalidPadding) { try MessageReceiver.unpad(Data([1, 2, 3])) }
        #expect(throws: ReceiveError.invalidPadding) { try MessageReceiver.unpad(Data([0, 0])) }
    }
}

@Suite struct SignalEnvironmentTests {
    @Test func configParses() throws {
        for env in SignalEnvironment.allCases {
            #expect(try env.serverTrustRoots().count == 2)
            #expect(env.endpoints.cdnURLs.keys.sorted() == [0, 2, 3])
        }
        #expect(SecCertificateCreateWithData(nil, SignalEnvironment.signalRootCertificateDER as CFData) != nil)
    }
}

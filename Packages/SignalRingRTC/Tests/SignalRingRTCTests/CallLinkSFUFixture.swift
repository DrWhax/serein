import Foundation
import SignalRingRTC

enum CallLinkSFUFixture {
    static func rootKey() throws -> CallLinkRootKey {
        try CallLinkRootKey.fromBytes(Data(repeating: 0x42, count: 16) + [1, 0, 0, 0, 87])
    }

    // Endorsement public key of the local test server's ServerSecretParams seed [71; 32].
    static let publicKey = bytes("00229c8343574f6ce021bc089bb7fe656251731845610c168833511f8fc2932067")

    // Generated with pinned zkgroup CallLinkSecretParams::encrypt_uid, one ACI per participant.
    static let ids = [
        "00dc17ab91e7a3fd817b4441e3c398358bab6b193588d05afca0de52accc93a170e8a02d41d0a9887ee1b19dea6eba9fe90de06b59fd7eb5cc6b7dd2a6d89ab904",
        "00d0ecd56bf0672cfb4785fbbfa200d68bd8f552d99d76419308688d2ec28a4540accdceb6aac09446889e1f530aef800097726c9c6d436d6f7b18b13519446d40",
        "006aa029c18f11d7d81b8246a4b04452941590aa2883aa54d011c3a50fafe0b60aac7bc06955816feeb4293de6f1a791709295d8a6283aaa398418c0db12e28534",
        "001835d73afae9281ea60ac0a0a93a0918b2a4caa4daa3ea18acf33c3d9589f2365e0913c053138eb9b63ae680d56121991a3f7f94460d95cb4756fc0137334a6d",
    ]
    static let ciphers = ids.map(bytes)

    private static func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.utf8.count, by: 2).compactMap { offset in
            UInt8(hex.dropFirst(offset).prefix(2), radix: 16)
        })
    }
}

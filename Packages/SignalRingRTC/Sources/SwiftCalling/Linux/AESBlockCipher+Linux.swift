#if os(Linux)
import CryptoKit
import CryptoExtras

struct AESBlockCipher {
    private let key: SymmetricKey
    init(_ key: SymmetricKey) throws {
        guard key.bitCount == 128 || key.bitCount == 256 else { throw CallingWireError.malformed }
        self.key = key
    }
    func encrypt(_ block: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var bytes = (0..<16).map { block[$0] }
        // permute only throws for an invalid key or block size. Both are fixed above.
        try! AES.permute(&bytes, key: key)
        return SIMD16(bytes)
    }
}
#endif

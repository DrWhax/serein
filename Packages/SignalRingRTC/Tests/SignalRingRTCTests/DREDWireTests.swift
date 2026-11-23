import Foundation
import Testing
@testable import SwiftCalling

struct DREDWireTests {
    // Upstream Opus 1.6.1 dred_encode_silk_frame + dred_ec_decode, C arch 0.
    // Hash inputs are the bit patterns of every dequantized state/latent float,
    // including the extra quantizer conditioning value in each decoder latent.
    @Test func agreesWithNativeEntropyCoderAndDecoder() throws {
        let vectors: [(Int, Int, Int, Int, Int, Int, UInt64, String)] = [
            (6, 5, 15, 8, 4, 4, 15550560347461140368, "6a4388aa1cc150b90bf787d5037b5dab9143819b21cce30b53226cd462178d7993e318ed2600b98dfe193b61e308af40574ddd8b4530"),
            (0, 7, 3, -38, 4, 4, 12802861897341569276, "0f01b4d178632449788b956ac43880040f53d873fe77cf816b7a09be0ac9b0f7f272f44999ec3aabbee968a8bfd000abc8fe0c3d2859621785b9ab391e7037c7c6889f685139a990b8cb5dc3e8477c8dfaeefbeab38cbd0c945f8a6f0771f8efc2754fabf5befa56ffeaff6eb9a25b341e4704eec94dfb30"),
            (14, 0, 14, 0, 4, 2, 10394225064705050362, "e0876729c4092a02d7b2a9013e9c1ec31702a2"),
            (4, 2, 15, 16, 12, 12, 14754309581571075660, "44038bb844d5480597f25fada3513379c0e09189896692f0437dfd392da2f46aecb16196a2f575b52dfa6913590d383445ff1e6ccb273e252cea97d425c438b05b5aba903b1f82b66a6cd5ecc8b4d2bb49fbe33ea5dff4217261f45a5cc64548eacbf03f4d57b66d7cc385b37f14ad7214436dad4030b509d53b221cbdfeffc35cb9cabd84738b98fa3efbb90f1c5a337bc8e7d5289fa29ea0bf358643b2b08eccf5ad05e5b786d112bc5cef5685e639209d39a6a15d1129576d239715edda097ee1c5570c1480"),
        ]
        let state = (0..<50).map { Float(($0 * 13 + 5) % 37 - 18) / 2 }
        for (q, step, maxQ, offset, count, decodedCount, hash, hex) in vectors {
            let history: [[Float]] = (0..<count).map { frame in
                (0..<25).map { i in Float((i * 7 + frame * 61 + 3) % 29 - 14) / 2 }
            }
            let data = try DREDWire.attach(to: Data([0xf8, 0xff, 0xfe]), state: state, latents: history, offset: offset,
                                           initialQ: q, step: step, maxQ: maxQ)
            let packet = try OpusPacket(data)
            #expect(packet.frames[0].copyBytes() == [0xff, 0xfe])
            let bytes = try #require(packet.findExtension { $0.id == 126 }).bytes.copyBytes()
            let encoded = bytes.dropFirst(2).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
            #expect(encoded == hex)
            var reference: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let next = hex.index(i, offsetBy: 2)
                reference.append(try #require(UInt8(hex[i..<next], radix: 16)))
                i = next
            }
            let native = try OpusPacket(Data([0xfb, 0x41, UInt8(reference.count + 3), 0xff, 0xfe, 252, 68, 12] + reference))
            let decoded = try #require(try DREDWire.decode(native))
            #expect(decoded.offset == offset && decoded.latents.count == decodedCount)
            let result = (decoded.state + decoded.latents.flatMap { $0 }).reduce(UInt64(14695981039346656037)) {
                ($0 ^ UInt64($1.bitPattern)) &* 1099511628211
            }
            #expect(result == hash)
        }
    }

    @Test func extensionPositionRepeatsAndVariableLengthFrames() throws {
        let state = [Float](repeating: 0, count: 50), latent = [Float](repeating: 0.25, count: 25)
        let base = try OpusPacket(DREDWire.attach(to: Data([0xf8, 9]), state: state, latents: [latent, latent], offset: -3))
        let dred = try #require(base.findExtension { $0.id == 126 }).bytes.copyBytes()
        // Wrong version on the first frame. Repeat supplies the valid version
        // on the second. Its long length is implicit, with a short extension after it.
        let padding: [UInt8] = [253, 3, 68, 11, 0, 7, 10, 4] + dred + [20]
        let input = Data([0xfb, 0xc2, UInt8(padding.count), 1, 10, 20, 30] + padding)
        let multi = try OpusPacket(input)
        #expect(multi.frames.map { $0.copyBytes() } == [[10], [20, 30]])
        let decoded = try #require(try DREDWire.decode(multi))
        #expect(decoded.offset == 5) // -3 + one 20 ms frame
        let preserved = try OpusPacket(multi.addingFirstFrameExtension(id: 60, bytes: [UInt8](repeating: 33, count: 510)))
        #expect(preserved.frames == multi.frames)
        #expect(try DREDWire.decode(preserved)?.offset == 5)
        #expect(try preserved.findExtension { $0.id == 60 }?.bytes.count == 510)
        let truncated = try OpusPacket(Data([0xfb, 0x41, 3, 0, 253, 255, 0]))
        #expect(throws: (any Error).self) { try DREDWire.decode(truncated) }
    }
}

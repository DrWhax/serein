import Foundation
@testable import SwiftCalling
import Testing
import VideoVP9

@Suite struct VP9AssemblyTests {
    private func packet(_ seq: UInt16, _ timestamp: UInt32, _ bytes: [UInt8], marker: Bool = false) -> RTPPayload {
        RTPPayload(type: 109, timestamp: timestamp, sequence: seq, marker: marker, rotation: 1, transportNumber: nil, bytes: Data(bytes))
    }

    @Test func reorderedEncryptedLayersShareOneTimestampAndWrap() throws {
        var stream = VP9Assembly()
        // Non-flexible mode, two spatial layers, an extended picture ID, and a
        // scalability structure with two resolutions and one picture group.
        let base = packet(.max, .max, [0xaa, 0x80, 3, 0, 2, 0x38, 0,32,0,32,0,64,0,64, 1,4,1, 0xa0])
        let baseEnd = packet(0, .max, [0xa4, 0x80,3, 0,2, 0xa1])
        let higher = packet(1, .max, [0xac, 0x80,3, 3,2, 0xb0], marker: true)
        #expect(try stream.assemble(higher).isEmpty)
        #expect(try stream.assemble(baseEnd).isEmpty)
        let frames = try stream.assemble(base)
        #expect(frames.map(\.spatialLayer) == [0,1])
        #expect(frames.map(\.bytes) == [Data([0xa0,0xa1]), Data([0xb0])])
        #expect(try stream.assemble(base).isEmpty)
        // Flexible predicted frame with two picture references.
        let next = try stream.assemble(packet(2, 0, [0xdc, 4, 3,4, 0xc0], marker: true))
        #expect(next.first?.bytes == Data([0xc0]))
        #expect(try stream.assemble(higher).isEmpty)
    }

    @Test func lossAndTruncationDoNotJoinDifferentPictures() throws {
        var stream = VP9Assembly()
        #expect(try stream.assemble(packet(2, 200, [8, 1])).isEmpty)
        #expect(try stream.assemble(packet(4, 200, [4, 3])).isEmpty)
        #expect(try stream.assemble(packet(5, 201, [12, 4])).first?.bytes == Data([4]))
        #expect(try stream.assemble(packet(3, 200, [0, 2])).isEmpty)
        for bytes: [UInt8] in [[0x1c, 0], [0xdc, 1, 3, 3, 3, 2], [0x8e, 1, 0xf0, 1], [12]] {
            #expect(throws: (any Error).self) { try stream.assemble(packet(6, 202, bytes)) }
        }
    }

    @Test func spatialKeyDependenciesSurviveFragmentation() throws {
        var encoder = try #require(VP9ScalableEncoder(mode: "L3T3_KEY"))
        var packetizer = ScalableVideoPacketizer()
        let y = [UInt8](repeating: 128, count: 32 * 32), uv = Array(y.prefix(16 * 16))
        let encoded = encoder.encode(width: 32, height: 32, y: y, u: uv, v: uv)
        let pictures = try #require(encoded)
        let layers = packetizer.describe(pictures, mode: "L3T3_KEY", bitrate: 1_000_000)
        try #require(layers.count == 3)
        #expect(layers[0].payload(start: true, end: false)[0] & 2 != 0)
        #expect(layers[0].payload(start: false, end: true)[0] & 2 == 0)
        // The intermediate spatial key layer is needed to decode both it and
        // the upper layer. The SFU reads that indication on every fragment.
        let head = try #require(layers[1].extensions(start: true, end: false).first?.1)
        let tail = try #require(layers[1].extensions(start: false, end: true).first?.1)
        #expect(head.count > 3 && head.dropFirst() == tail.dropFirst())
        #expect(head[0] ^ tail[0] == 0xc0)
    }
}

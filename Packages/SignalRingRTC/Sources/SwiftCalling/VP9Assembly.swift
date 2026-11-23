import CodecCore
import Foundation

/// RFC 9628. Every spatial layer is a separate encoded (and, in groups, encrypted)
/// frame. The RTP marker only identifies the last layer of the whole picture.
struct VP9Assembly {
    static let payloadType: UInt8 = 109

    struct Frame: Sendable {
        let bytes: Data
        let spatialLayer: Int
        let rotation: Int
        let timestamp: UInt32
        let start, end: UInt16
        /// The picture ID (7 or 15 bits): spatial layers of one picture share it, and the next
        /// picture's is one more. RTP sequence numbers can skip packets that are not video (FEC).
        var pictureID: Int? = nil
        var pictureIDMask = 0x7fff
    }

    private struct Descriptor {
        let begins, ends, dependsOnLower: Bool
        let spatial: Int
        let payload: Data
        var pictureID: Int?, pictureIDMask = 0x7fff

        init(_ bytes: Data) throws {
            var input = ByteCursor(Array(bytes))
            let flags = try input.u8()
            let flexible = flags & 0x10 != 0
            begins = flags & 0x08 != 0
            ends = flags & 0x04 != 0
            if flags & 0x80 != 0 {
                let high = try input.u8()
                if high & 0x80 != 0 {
                    pictureID = Int(high & 0x7f) << 8 | Int(try input.u8())
                } else {
                    pictureID = Int(high)
                    pictureIDMask = 0x7f
                }
            } else if flexible { throw CallingWireError.malformed }
            if flags & 0x20 != 0 {
                let layer = try input.u8()
                spatial = Int(layer >> 1 & 7)
                dependsOnLower = layer & 1 != 0
                guard spatial > 0 || !dependsOnLower else { throw CallingWireError.malformed }
                if !flexible { try input.skip(1) }
            } else {
                spatial = 0
                dependsOnLower = false
            }
            if flexible && flags & 0x40 != 0 {
                for index in 0..<3 {
                    let reference = try input.u8()
                    guard reference >> 1 != 0 else { throw CallingWireError.malformed }
                    if reference & 1 == 0 { break }
                    if index == 2 { throw CallingWireError.malformed }
                }
            }
            if flags & 2 != 0 {
                let structure = try input.u8()
                if structure & 0x10 != 0 { try input.skip(4 * (1 + Int(structure >> 5))) }
                if structure & 8 != 0 {
                    let descriptions = Int(try input.u8())
                    for _ in 0..<descriptions {
                        let group = try input.u8()
                        try input.skip(Int(group >> 2 & 3))
                    }
                }
            }
            guard !input.isAtEnd else { throw CallingWireError.malformed }
            payload = Data(input.rest().copyBytes())
        }
    }

    private struct Layer {
        let dependsOnLower: Bool
        var start: UInt16?
        var end: UInt16?
        var rotation = 0
        var pictureID: Int?, pictureIDMask = 0x7fff
        var parts: [UInt16: Data] = [:]

        var complete: Data? {
            guard let start, let end, Int(end &- start) + 1 == parts.count else { return nil }
            var result = Data()
            for offset in 0..<parts.count {
                guard let part = parts[start &+ UInt16(offset)] else { return nil }
                result.append(part)
            }
            return result
        }
    }

    private var timestamp: UInt32?
    private var layers: [Int: Layer] = [:]
    private var lastEmitted = -1
    private var totalBytes = 0
    private var packets = 0

    mutating func assemble(_ packet: RTPPayload) throws -> [Frame] {
        guard packet.type == Self.payloadType else { return [] }
        let descriptor = try Descriptor(packet.bytes)
        if let timestamp, Int32(bitPattern: packet.timestamp &- timestamp) < 0 { return [] }
        if timestamp != packet.timestamp {
            self = VP9Assembly()
            timestamp = packet.timestamp
        }
        let spatial = descriptor.spatial
        guard spatial > lastEmitted, layers[spatial]?.parts[packet.sequence] == nil else { return [] }
        guard packets < 2048, totalBytes + descriptor.payload.count <= DirectVideoStream.maxPictureBytes else {
            layers.removeAll()
            lastEmitted = 7
            throw CallingWireError.tooLarge
        }
        if layers[spatial] == nil {
            layers[spatial] = Layer(dependsOnLower: descriptor.dependsOnLower, pictureID: descriptor.pictureID, pictureIDMask: descriptor.pictureIDMask)
        }
        guard layers[spatial]?.dependsOnLower == descriptor.dependsOnLower else { throw CallingWireError.malformed }
        if descriptor.begins { layers[spatial]?.start = packet.sequence }
        if descriptor.ends {
            layers[spatial]?.end = packet.sequence
            layers[spatial]?.rotation = packet.rotation
        }
        layers[spatial]?.parts[packet.sequence] = descriptor.payload
        totalBytes += descriptor.payload.count
        packets += 1

        var output: [Frame] = []
        for id in layers.keys.sorted() where id > lastEmitted {
            guard let layer = layers[id] else { continue }
            if layer.dependsOnLower && lastEmitted != id - 1 { break }
            guard let start = layer.start, let end = layer.end, let bytes = layer.complete else { break }
            output.append(Frame(bytes: bytes, spatialLayer: id, rotation: layer.rotation, timestamp: packet.timestamp, start: start, end: end,
                                pictureID: layer.pictureID, pictureIDMask: layer.pictureIDMask))
            layers.removeValue(forKey: id)
            lastEmitted = id
        }
        return output
    }
}

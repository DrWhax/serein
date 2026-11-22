import CodecCore
import Foundation
import VideoVP9

package struct GroupVideoConfiguration: Sendable {
    let camera, screen: String
    let maximumBitrate: UInt64?
    package init?(camera: String, screen: String, maximumBitrate: UInt64?) {
        guard VP9ScalableEncoder(mode: camera) != nil, VP9ScalableEncoder(mode: screen) != nil else { return nil }
        self.camera = camera
        self.screen = screen
        self.maximumBitrate = maximumBitrate
    }

    func mode(screenSharing: Bool, width: Int, height: Int) -> String {
        let configured = screenSharing ? screen : camera
        let bytes = Array(configured.utf8)
        let requested = Int(bytes[1] - 48)
        // RingRTC avoids extra spatial encoders below 240×135, in either orientation.
        let ratio = min(max(width,height) / 240, min(width,height) / 135)
        let count = min(requested, ratio >= 4 ? 3 : ratio >= 2 ? 2 : 1)
        if count == requested { return configured }
        if count == 1 { return "L1T" + String(decoding: bytes[3...3], as: UTF8.self) }
        var limited = bytes
        limited[1] = UInt8(48 + count)
        return String(decoding: limited, as: UTF8.self)
    }
}

/// Signal uses RFC 9628 plus the AOM dependency descriptor and WebRTC video
/// layers allocation on the group SVC SSRC. Picture IDs advance per image,
/// dependency-descriptor frame numbers advance per independently sealed layer.
struct ScalableVideoPacketizer {
    struct Layer {
        let frame: VP9EncodedLayer
        let pictureID, frameID: UInt16
        let lastSpatial, usedByUpperLayer: Bool
        let descriptor, continuationDescriptor: [UInt8]
        let allocation: [UInt8]?
        let scalabilityStructure: [UInt8]?

        func payload(start: Bool, end: Bool) -> Data {
            var flags: UInt8 = frame.temporalReferenceDiff == nil ? 0xb0 : 0xf0
            if start { flags |= 8 }
            if end { flags |= 4 }
            if start, scalabilityStructure != nil { flags |= 2 }
            if !usedByUpperLayer { flags |= 1 }
            var layer = UInt8(frame.temporalID << 5 | frame.spatialID << 1)
            if frame.switchingUp { layer |= 16 }
            if frame.dependsOnLower { layer |= 1 }
            var bytes = Data([flags, UInt8(truncatingIfNeeded: pictureID >> 8) | 128, UInt8(truncatingIfNeeded: pictureID), layer])
            if let diff = frame.temporalReferenceDiff { bytes.append(UInt8(diff << 1)) }
            if start, let scalabilityStructure { bytes.append(contentsOf: scalabilityStructure) }
            return bytes
        }

        func extensions(start: Bool, end: Bool) -> [(UInt8,[UInt8])] {
            var header = start ? descriptor : continuationDescriptor
            header[0] = header[0] & 63 | (start ? 128 : 0) | (end ? 64 : 0)
            if start, let allocation { return [(6,header),(14,allocation)] }
            return [(6,header)]
        }
    }

    private var pictureID: UInt16 = 0, frameID: UInt16 = 0
    private var lastChain = [UInt16?](repeating: nil, count: 3)

    mutating func describe(_ layers: [VP9EncodedLayer], mode: String, bitrate: Int) -> [Layer] {
        guard let first = layers.first, let temporalByte = mode.utf8.dropFirst(3).first,
              (49...51).contains(temporalByte), (1...3).contains(layers.count) else { return [] }
        let temporal = Int(temporalByte - 48), spatial = layers.count
        let crossLayer = mode.hasPrefix("L") && !mode.contains("_KEY")
        pictureID &+= 1
        if first.refresh { lastChain = .init(repeating: nil, count: 3) }
        let allocation = first.refresh ? Self.allocation(layers, temporal: temporal, bitrate: bitrate) : nil
        // RFC 9628 section 4.2.1. Transmit the number and dimensions of the
        // spatial layers on the first packet of the base-layer key picture.
        var scalabilityStructure = [UInt8((spatial - 1) << 5 | 0x10)]
        for layer in layers {
            for dimension in [layer.width, layer.height] {
                scalabilityStructure.append(UInt8(dimension >> 8))
                scalabilityStructure.append(UInt8(truncatingIfNeeded: dimension))
            }
        }
        return layers.map { frame in
            frameID &+= 1
            let idx = frame.spatialID * temporal + frame.temporalID
            let structure = frame.refresh && !frame.dependsOnLower
            let indications = (0..<(spatial * temporal)).map { target in
                let s = target / temporal, t = target % temporal
                let present = (s == frame.spatialID || (s > frame.spatialID && (crossLayer || frame.refresh && mode.hasPrefix("L")))) && t >= frame.temporalID
                guard present else { return 0 }
                if frame.refresh { return 2 }
                if !crossLayer {
                    return frame.temporalID > 0 && t == frame.temporalID ? 1 : 2
                }
                return frame.switchingUp ? 2 : 3
            }
            var diffs: [Int] = []
            if frame.dependsOnLower { diffs.append(1) }
            if let diff = frame.temporalReferenceDiff { diffs.append(diff * spatial) }
            let distances = lastChain.prefix(spatial).map { last in last.map { min(255, Int(frameID &- $0)) } ?? 0 }
            let number = frameID
            func header(withStructure: Bool) -> [UInt8] {
                var bits = MSBBitWriter()
                bits.write(idx,8)
                bits.write(Int(number),16)
                bits.write((withStructure ? 16 : 0) | 7,5)
                if withStructure { Self.structure(layers, temporal: temporal, crossLayer: crossLayer, into: &bits) }
                for dti in indications { bits.write(dti,2) }
                for diff in diffs {
                    let n = diff <= 16 ? 1 : 2
                    bits.write(n,2)
                    bits.write(diff-1,4*n)
                }
                bits.write(0,2)
                for distance in distances { bits.write(distance,8) }
                return bits.finish()
            }
            if frame.temporalID == 0 {
                for chain in frame.spatialID..<spatial where chain == frame.spatialID || crossLayer || frame.refresh && mode.hasPrefix("L") {
                    lastChain[chain] = frameID
                }
            }
            // An SFU can filter each packet using its DTI. A lower layer of an
            // inter-layer key picture must reach the upper target in its entirety.
            let continuation = header(withStructure: false)
            let lastSpatial = frame.spatialID == spatial - 1
            return Layer(frame: frame, pictureID: pictureID, frameID: frameID, lastSpatial: lastSpatial,
                         usedByUpperLayer: !lastSpatial && layers[frame.spatialID + 1].dependsOnLower,
                         descriptor: structure ? header(withStructure: true) : continuation, continuationDescriptor: continuation,
                         allocation: structure && frame.spatialID == 0 ? allocation : nil,
                         scalabilityStructure: structure ? scalabilityStructure : nil)
        }
    }

    private static func writeNS(_ value: Int, possibilities: Int, into bits: inout MSBBitWriter) {
        let width = Int.bitWidth - possibilities.leadingZeroBitCount
        let short = (1 << width) - possibilities
        if value < short { bits.write(value,width-1) }
        else { bits.write(value+short,width) }
    }

    private static func structure(_ layers: [VP9EncodedLayer], temporal: Int, crossLayer: Bool, into bits: inout MSBBitWriter) {
        let spatial = layers.count, targets = spatial * temporal
        bits.write(0,6)
        bits.write(targets-1,5)
        for i in 0..<targets {
            bits.write(i == targets-1 ? 3 : ((i+1).isMultiple(of: temporal) ? 2 : 1), 2)
        }
        for i in 0..<targets {
            for target in 0..<targets {
                let s = target/temporal, t = target%temporal
                bits.write((s == i/temporal || crossLayer && s > i/temporal) && t >= i%temporal ? 3 : 0,2)
            }
        }
        for _ in 0..<targets { bits.write(0,1) } // All temporal references are sent explicitly on their frame.
        writeNS(spatial, possibilities: targets+1, into: &bits)
        for target in 0..<targets { writeNS(target/temporal, possibilities: spatial, into: &bits) }
        for _ in 0..<(targets*spatial) { bits.write(0,4) }
        bits.write(1,1)
        for layer in layers { bits.write(layer.width-1,16); bits.write(layer.height-1,16) }
    }

    private static func allocation(_ layers: [VP9EncodedLayer], temporal: Int, bitrate: Int) -> [UInt8] {
        // One RTP stream, one active bit and one size entry per spatial layer.
        var bits = MSBBitWriter()
        bits.write((1 << layers.count)-1,8)
        for _ in layers { bits.write(temporal-1,2) }
        var bytes = bits.finish()
        let pixels = layers.reduce(0) { $0 + $1.width * $1.height }
        for layer in layers {
            for t in 1...temporal {
                var kbps = max(1, bitrate * layer.width * layer.height / pixels * t / temporal / 1000)
                while kbps >= 128 { bytes.append(UInt8(kbps & 127) | 128); kbps >>= 7 }
                bytes.append(UInt8(kbps))
            }
        }
        for layer in layers {
            for value in [layer.width-1, layer.height-1] { bytes += [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)] }
            bytes.append(30)
        }
        return bytes
    }
}

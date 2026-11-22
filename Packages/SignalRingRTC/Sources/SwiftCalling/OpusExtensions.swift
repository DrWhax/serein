// Opus extension framing from libopus 1.6.1 src/extensions.c.
// Copyright (c) 2022 Amazon. See LICENSE-Opus.txt.
import CodecCore
import Foundation

extension OpusPacket {
    struct FrameExtension {
        let id: UInt8
        let frame: Int
        let bytes: ByteSlice
    }

    /// Stop at the first match, including copies encoded by a Repeat These Extensions header.
    func findExtension(_ visit: (FrameExtension) throws -> Bool) throws -> FrameExtension? {
        var cursor = padding.cursor()
        var frame = 0
        var repeatHeaders: [UInt8] = []
        var lastLong: Int?
        var trailingShortBytes = 0

        func payload(header: UInt8, cursor: inout ByteCursor, trailing: Int = 0) throws -> ByteSlice {
            let id = header >> 1, lengthBit = Int(header & 1)
            if header == 1 || id == 2 { return .empty }
            if id > 0, id < 32 { return try cursor.bytes(lengthBit) }
            if lengthBit == 0 { return try cursor.bytes(cursor.remaining - trailing) }
            var length = 0
            var octet: UInt8
            repeat {
                octet = try cursor.u8()
                length += Int(octet)
                guard length <= cursor.remaining else { throw Failure.invalidPacket }
            } while octet == 255
            return try cursor.bytes(length)
        }

        while !cursor.isAtEnd {
            let header = try cursor.u8(), id = header >> 1
            let bytes = try payload(header: header, cursor: &cursor)
            switch id {
            case 0: continue
            case 1:
                var offset = bytes.cursor()
                let increment = header == 2 ? 1 : Int(try offset.u8())
                guard increment != 0 else { continue }
                frame += increment
                guard frame < frames.count else { throw Failure.invalidPacket }
                repeatHeaders.removeAll(keepingCapacity: true)
                lastLong = nil
                trailingShortBytes = 0
            case 2:
                for nextFrame in (frame + 1)..<frames.count {
                    for (index, original) in repeatHeaders.enumerated() {
                        let implicit = header == 4 && index == lastLong && nextFrame == frames.count - 1
                        let copy = try payload(header: implicit ? original & 0xfe : original,
                                               cursor: &cursor, trailing: trailingShortBytes)
                        let item = FrameExtension(id: original >> 1, frame: nextFrame, bytes: copy)
                        if try visit(item) { return item }
                    }
                }
                repeatHeaders.removeAll(keepingCapacity: true)
                lastLong = nil
                trailingShortBytes = 0
                if header == 4 {
                    frame += 1
                    if frame == frames.count { return nil }
                }
            default:
                if id >= 32 {
                    lastLong = repeatHeaders.count
                    trailingShortBytes = 0
                } else { trailingShortBytes += Int(header & 1) }
                repeatHeaders.append(header)
                let item = FrameExtension(id: id, frame: frame, bytes: bytes)
                if try visit(item) { return item }
            }
        }
        return nil
    }

    /// Serialize extension records explicitly, retaining the frame association of any
    /// existing padding extensions. No Opus audio data is decoded or re-encoded here.
    func addingFirstFrameExtension(id: UInt8, bytes: [UInt8]) throws -> Data {
        guard (32...127).contains(id), !bytes.isEmpty else { throw Failure.invalidPacket }
        var extensions = [FrameExtension(id: id, frame: 0, bytes: ByteSlice(bytes))]
        var extensionBytes = bytes.count + 1
        _ = try findExtension { item in
            extensionBytes += item.bytes.count + 1
            guard extensionBytes <= 65_507 else { throw Failure.invalidPacket }
            extensions.append(item)
            return false
        }
        extensions.sort { $0.frame < $1.frame }
        var padding: [UInt8] = []
        var currentFrame = 0
        for (index, item) in extensions.enumerated() {
            if item.frame > currentFrame {
                let increment = item.frame - currentFrame
                padding += increment == 1 ? [2] : [3, UInt8(increment)]
                currentFrame = item.frame
            }
            if item.id < 32 {
                padding.append(item.id * 2 + UInt8(item.bytes.count))
            } else if index == extensions.count - 1 {
                padding.append(item.id * 2)
            } else {
                padding.append(item.id * 2 + 1)
                padding.append(contentsOf: repeatElement(255, count: item.bytes.count / 255))
                padding.append(UInt8(item.bytes.count % 255))
            }
            item.bytes.append(to: &padding)
        }
        let variable = frames.contains { $0.count != frames[0].count }
        let toc = configuration << 3 | (stereo ? 4 : 0) | 3
        var packet = [toc, UInt8(frames.count) | 64 | (variable ? 128 : 0)]
        packet.append(contentsOf: repeatElement(255, count: padding.count / 254))
        packet.append(UInt8(padding.count % 254))
        if variable {
            for frame in frames.dropLast() {
                let length = frame.count
                if length < 252 { packet.append(UInt8(length)) }
                else {
                    let first = 252 + length % 4
                    packet += [UInt8(first), UInt8((length - first) / 4)]
                }
            }
        }
        for frame in frames { frame.append(to: &packet) }
        guard packet.count + padding.count <= 65_507 else { throw Failure.invalidPacket }
        return Data(packet + padding)
    }
}

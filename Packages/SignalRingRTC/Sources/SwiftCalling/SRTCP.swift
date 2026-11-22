import CodecCore
import CryptoKit
import Foundation
import Synchronization

/// RFC 7714 encrypted RTCP. Only the first packet's common header and SSRC are clear.
private func checkRTCPHeader(_ packet: Data, ssrc: UInt32, minimum: Int) throws {
    guard (minimum...65_507).contains(packet.count), packet.count.isMultiple(of: 4) else { throw SRTPError.invalidPacket }
    var header = ByteCursor(Array(packet.prefix(8)))
    guard try header.u8() >> 6 == 2, (192...223).contains(try header.u8()) else { throw SRTPError.invalidPacket }
    try header.skip(2)
    guard try header.u32be() == ssrc else { throw SRTPError.invalidPacket }
}

final class SRTCPSender: Sendable {
    let keys: SRTPKeys
    let ssrc: UInt32
    private let nextIndex: Mutex<UInt32>

    init(keys: SRTPKeys, ssrc: UInt32, startingAt index: UInt32 = 1) {
        self.keys = keys
        self.ssrc = ssrc
        nextIndex = Mutex(index)
    }

    func seal(_ packet: Data) throws -> Data {
        try checkRTCPHeader(packet, ssrc: ssrc, minimum: 8)
        guard packet.count <= 65_507 - 20 else { throw SRTPError.invalidPacket }
        let index = try nextIndex.withLock { value in
            guard value < 1 << 31 else { throw SRTPError.exhausted }
            defer { value += 1 }
            return value
        }
        let word = index | 0x8000_0000
        let indexBytes = Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> $0) })
        let header = packet.prefix(8)
        let nonce = try keys.nonce(ssrc: ssrc, index: UInt64(index))
        let box = try AES.GCM.seal(packet.dropFirst(8), using: keys.key, nonce: nonce, authenticating: header + indexBytes)
        return header + box.ciphertext + box.tag + indexBytes
    }
}

final class SRTCPReceiver: Sendable {
    let keys: SRTPKeys
    let ssrc: UInt32
    private let window = Mutex(SRTPReplayWindow())

    init(keys: SRTPKeys, ssrc: UInt32) {
        self.keys = keys
        self.ssrc = ssrc
    }

    func open(_ packet: Data) throws -> Data {
        try checkRTCPHeader(packet, ssrc: ssrc, minimum: 28)
        let indexBytes = packet.suffix(4)
        var field = ByteCursor(Array(indexBytes))
        let word = try field.u32be()
        guard word >> 31 == 1 else { throw SRTPError.invalidPacket }
        let index = UInt64(word & 0x7fff_ffff)
        let header = packet.prefix(8)
        let cipher = packet.dropFirst(8).dropLast(20)
        let tag = packet.dropLast(4).suffix(16)
        return try window.withLock { state in
            try state.check(index)
            let box = try AES.GCM.SealedBox(nonce: keys.nonce(ssrc: ssrc, index: index), ciphertext: cipher, tag: tag)
            let plain = try AES.GCM.open(box, using: keys.key, authenticating: header + indexBytes)
            state.accept(index)
            return header + plain
        }
    }
}

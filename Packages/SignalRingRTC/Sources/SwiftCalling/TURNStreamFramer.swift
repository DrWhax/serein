import Foundation

/// STUN has its own length header on a TURN byte stream (RFC 8656 section 5).
/// Unbound ChannelData is consumed with its four-byte padding and discarded.
struct TURNStreamFramer {
    static let chunkSize = 16 * 1024
    private var pending = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard chunk.count <= Self.chunkSize else { throw TURNMessage.Failure.malformed }
        pending.append(chunk)
        var packets: [Data] = []
        while pending.count >= 4 {
            let start = pending.startIndex
            let size = Int(pending[start + 2]) * 256 + Int(pending[start + 3])
            let isSTUN = pending[start] & 0xc0 == 0
            let total: Int
            if isSTUN {
                total = 20 + size
                guard size.isMultiple(of: 4), total <= 65_507 else { throw TURNMessage.Failure.malformed }
                if pending.count >= 8, !pending[start + 4..<start + 8].elementsEqual(TURNMessage.cookie) { throw TURNMessage.Failure.malformed }
            } else {
                guard pending[start] & 0xc0 == 0x40 else { throw TURNMessage.Failure.malformed }
                total = 4 + ((size + 3) / 4) * 4
            }
            guard pending.count >= total else { break }
            if isSTUN { packets.append(Data(pending.prefix(total))) }
            pending.removeFirst(total)
        }
        return packets
    }
}

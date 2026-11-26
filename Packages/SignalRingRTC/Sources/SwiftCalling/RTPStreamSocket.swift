import Foundation
#if !os(Linux)
import Network
import Security
#endif
import Synchronization

/// ICE-TCP carries STUN, RTP and RTCP in RFC 4571 network-order length frames.
/// Empty frames are keepalives. TURN's client stream uses a different wire format.
struct RTPStreamFramer {
    private var pending = Data()

    static func encode(_ datagram: Data) throws -> Data {
        guard let size = UInt16(exactly: datagram.count) else { throw CallingWireError.tooLarge }
        return Data([UInt8(size >> 8), UInt8(truncatingIfNeeded: size)]) + datagram
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard chunk.count <= TURNStreamFramer.chunkSize else { throw CallingWireError.tooLarge }
        pending.append(chunk)
        var messages: [Data] = []
        while pending.count >= 2 {
            let start = pending.startIndex
            let length = Int(pending[start]) * 256 + Int(pending[start + 1])
            guard pending.count >= length + 2 else { break }
            if length != 0 { messages.append(Data(pending[start + 2..<start + 2 + length])) }
            pending.removeFirst(length + 2)
        }
        return messages
    }
}

final class RTPStreamSocket: Sendable {
    private let connection: TURNConnection
    var networkPath: NWPath? { connection.networkPath }
    private struct State {
        var framer = RTPStreamFramer()
        var closed = false
        var queuedBytes = 0
    }
    private let state = Mutex(State())

    init(server: TURNServerEndpoint, dialHostname: Bool, trustAnchor: SecCertificate?) {
        connection = TURNConnection(server: server, dialHostname: dialHostname, trustAnchor: trustAnchor)
    }

    func start(receive: @escaping @Sendable (Data) -> Void, ended: @escaping @Sendable () -> Void) {
        connection.start()
        read(receive: receive, ended: ended)
    }

    private func read(receive: @escaping @Sendable (Data) -> Void, ended: @escaping @Sendable () -> Void) {
        connection.read { [weak self] chunk, end in
            guard let self else { return }
            do {
                if let chunk {
                    let packets = try state.withLock { try $0.framer.append(chunk) }
                    for packet in packets { receive(packet) }
                }
                if end { ended(); return }
                if !state.withLock({ $0.closed }) { read(receive: receive, ended: ended) }
            } catch { ended() }
        }
    }

    func send(_ data: Data) throws {
        let packet = try RTPStreamFramer.encode(data)
        let size = packet.count
        try state.withLock {
            guard !$0.closed else { throw DirectICETransport.Failure.noConsent }
            guard size <= 1_048_576 - $0.queuedBytes else { throw CallingWireError.tooLarge }
            $0.queuedBytes += size
        }
        connection.send(packet) { [weak self] ok in
            guard let self else { return }
            state.withLock { $0.queuedBytes -= size }
            if !ok { close() }
        }
    }

    func close() {
        let first = state.withLock { state in
            let first = !state.closed
            state.closed = true
            return first
        }
        if first { connection.cancel() }
    }
}

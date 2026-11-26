#if os(Linux)
import Foundation

// The production caller uses system trust. Tests can supply one DER trust anchor.
package typealias SecCertificate = Data

struct TURNConnection: Sendable {
    private let connection: NWConnection
    let isStream: Bool

    init(server: TURNServerEndpoint, dialHostname: Bool, trustAnchor: SecCertificate?) {
        isStream = server.transport != .udp
        if !isStream {
            connection = NWConnection(to: server.address, using: .udp)
        } else {
            let identity = server.tlsHostname ?? server.host
            let destination = dialHostname ? identity : server.host
            connection = NWConnection(to: .hostPort(host: .init(destination), port: server.port),
                                      tlsIdentity: server.transport == .tls ? identity : nil, root: trustAnchor)
        }
    }
    var networkPath: NWPath? { connection.currentPath }
    func start() { connection.start(queue: DispatchQueue.global(qos: .userInitiated)) }
    func read(_ complete: @escaping @Sendable (Data?, Bool) -> Void) {
        connection.read(max: isStream ? TURNStreamFramer.chunkSize : 65536) { bytes, eof, error in
            complete(bytes, eof || error != nil)
        }
    }
    func send(_ bytes: Data, completion: @escaping @Sendable (Bool) -> Void) {
        connection.send(content: bytes, completion: .contentProcessed { completion($0 == nil) })
    }
    func cancel() { connection.cancel() }
}
#endif

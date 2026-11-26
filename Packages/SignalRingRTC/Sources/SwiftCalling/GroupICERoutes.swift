import Foundation
#if !os(Linux)
import Security
import Network
#endif

struct GroupICERoutes: Sendable {
    struct Address: Hashable, Sendable {
        let transport: TURNClientTransport
        let host: String
        let port: UInt16
        let tlsHostname: String?
    }
    struct Nomination: Sendable {
        let address: Address
        let transport: DirectICETransport
    }
    let routes: [(Address, DirectICETransport.Route)]
    init(udp: [String], tcp: [String], tls: [String], hostname: String?) {
        var routes: [(Address, DirectICETransport.Route)] = []
        for (addresses, transport) in [(udp,TURNClientTransport.udp), (tcp,.tcp), (tls,.tls)] {
            for address in addresses.prefix(8) {
                guard address.lastIndex(of: ":") != nil else { continue }
                let scheme = transport == .tls ? "turns:" : "turn:"
                let query = transport == .tcp ? "?transport=tcp" : ""
                guard let endpoint = TURNServerEndpoint(scheme + address + query, hostname: hostname ?? ""),
                      let candidate = ICEHostCandidate(observed: endpoint.address) else { continue }
                let address = Address(transport: transport, host: endpoint.host, port: endpoint.port.rawValue,
                                      tlsHostname: endpoint.tlsHostname)
                if !routes.contains(where: { $0.0 == address }) {
                    routes.append((address, transport == .udp ? .host(candidate) : .sfuStream(candidate,endpoint)))
                }
            }
        }
        self.routes = routes
    }

    func connect(local: DirectICETransport.Credentials, remote: DirectICETransport.Credentials, trustAnchor: SecCertificate? = nil,
                 receive: @escaping @Sendable (Data) -> Void) async throws -> Nomination {
        let role = ICEBinding.Role.controlling(UInt64.random(in: .min ... .max))
        // Prefer UDP. Stagger the alternatives so a black-holed address does not
        // delay TCP/TLS fallback for the full ICE transaction timeout.
        return try await withThrowingTaskGroup(of: Nomination?.self) { group in
            for (i,(address, route)) in routes.enumerated() {
                group.addTask {
                    do {
                        try await Task.sleep(for: .milliseconds(i*250))
                        let transport = try await DirectICETransport.connect(route: route, relayOnly: false, local: local,
                            remote: remote, role: role, trustAnchor: trustAnchor, receive: receive)
                        if Task.isCancelled { transport.close(); return nil }
                        return Nomination(address: address, transport: transport)
                    } catch { return nil }
                }
            }
            var winner: Nomination?
            for try await result in group {
                if let result {
                    if winner == nil { winner = result; group.cancelAll() }
                    else { result.transport.close() }
                }
            }
            guard let winner else { throw DirectICETransport.Failure.nominationTimeout }
            if Task.isCancelled { winner.transport.close(); throw CancellationError() }
            return winner
        }
    }
}

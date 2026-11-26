import Foundation
#if !os(Linux)
import Network
#endif

/// Reserve an ephemeral UDP port while trickling candidates. A connected UDP socket on
/// the same port handles the selected remote tuple, including its authenticated ICE checks.
final class VoiceHostPort: Sendable {
    private let listener: NWListener
    let port: NWEndpoint.Port
    let candidates: [IceCandidateUpdate]

    private init(listener: NWListener, port: NWEndpoint.Port, candidates: [IceCandidateUpdate]) {
        self.listener = listener
        self.port = port
        self.candidates = candidates
    }

    static func gather(timeoutAfter: Duration = .seconds(10), keepPortOnLookupTimeout: Bool = false,
                       inbound: @escaping @Sendable (NWConnection) -> Void = { $0.cancel() },
                       localAddresses: @escaping @Sendable () -> [String] = {
                           #if os(Linux)
                           NWPath.localAddresses
                           #else
                           Host.current().addresses
                           #endif
                       }) async throws -> VoiceHostPort {
        let settings = NWParameters.udp
        settings.allowLocalEndpointReuse = true
        let listener = try NWListener(using: settings)
        let discovery = AsyncStream<[IceCandidateUpdate]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = DispatchQueue(label: "serein.call.host-udp")
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                guard let port = listener?.port else { discovery.continuation.finish(); return }
                // Name service is synchronous and can be unavailable inside Seatbelt.
                // Resolve away from both the session actor and the listener's queue.
                DispatchQueue.global(qos: .utility).async {
                    discovery.continuation.yield(candidates(port: port, addresses: localAddresses()))
                    discovery.continuation.finish()
                }
            case .failed, .cancelled: discovery.continuation.finish()
            default: break
            }
        }
        listener.newConnectionHandler = inbound
        listener.start(queue: queue)
        let timeout = Task {
            try await Task.sleep(for: timeoutAfter)
            discovery.continuation.finish()
        }
        defer { timeout.cancel(); discovery.continuation.finish() }
        for await candidates in discovery.stream {
            if !Task.isCancelled, let port = listener.port {
                return VoiceHostPort(listener: listener, port: port, candidates: candidates)
            }
        }
        // Seatbelt can prevent local name service from enumerating interfaces. The
        // ready socket is sufficient for server-reflexive discovery on a direct call.
        if keepPortOnLookupTimeout, !Task.isCancelled, case .ready = listener.state, let port = listener.port {
            return VoiceHostPort(listener: listener, port: port, candidates: [])
        }
        listener.cancel()
        throw DirectICETransport.Failure.noConsent
    }

    private static func candidates(port: NWEndpoint.Port, addresses localAddresses: [String]) -> [IceCandidateUpdate] {
        var ipv4: [String] = [], ipv6: [String] = []
        for ip in localAddresses {
            if let address = IPv4Address(ip), !address.isLoopback, !address.isLinkLocal,
               !address.isMulticast, address != .any, address != .broadcast {
                ipv4.append(ip)
            } else if let address = IPv6Address(ip), !address.isLoopback, !address.isLinkLocal,
                      !address.isMulticast, address != .any, address.asIPv4 == nil, !ip.contains("%") {
                ipv6.append(ip)
            }
        }
        // Foundation's interface order can change between calls. Prefer IPv4 on
        // dual-stack networks and retain IPv6 for IPv6-only or failed IPv4 routes.
        return (ipv4 + ipv6).prefix(16).enumerated().map { index, address in
            IceCandidateUpdate(addedSDP: "candidate:\(index + 2) 1 udp \(2_130_706_431 - index * 256) \(address) \(port.rawValue) typ host")
        }
    }

    func close() { listener.cancel() }
    deinit { listener.cancel() }
}

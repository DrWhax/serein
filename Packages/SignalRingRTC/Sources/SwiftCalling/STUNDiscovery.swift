import Foundation
#if !os(Linux)
import Network
#endif

/// Server-reflexive candidates for direct calls. Probe a configured STUN or UDP TURN
/// server from the same UDP port the ICE listener uses (RFC 8445 §5.1.1.2).
enum STUNDiscovery {
    struct Mapping: Sendable {
        let address: ICEBinding.Address
        let candidate: IceCandidateUpdate
    }

    static func gather(servers: [VoiceTURNServer], port: NWEndpoint.Port,
                       found: @escaping @Sendable (Mapping) async -> Void) async {
        var seen: Set<NWEndpoint> = []
        var targets: [TURNServerEndpoint] = []
        for server in servers.prefix(16) {
            for url in server.urls.prefix(16) {
                if let endpoint = TURNServerEndpoint(stunURI: url), targets.count < 8,
                   seen.insert(endpoint.address).inserted { targets.append(endpoint) }
            }
        }
        await withTaskGroup(of: Mapping?.self) { group in
            for (index, target) in targets.enumerated() {
                for ipv6 in [false, true] {
                    if ipv6 && IPv4Address(target.host) != nil || !ipv6 && IPv6Address(target.host) != nil { continue }
                    group.addTask { await probe(target, port: port, ipv6: ipv6, index: 2*index + (ipv6 ? 1 : 0)) }
                }
            }
            for await mapping in group {
                if let mapping, !Task.isCancelled { await found(mapping) }
            }
        }
    }

    private static func probe(_ server: TURNServerEndpoint, port: NWEndpoint.Port, ipv6: Bool, index: Int) async -> Mapping? {
        let id = TURNMessage.newID()
        guard let request = try? TURNMessage.packet(0x0001, id: id, attributes: []) else { return nil }
        let parameters = NWParameters.udp
        let host: NWEndpoint.Host = ipv6 ? .ipv6(.any) : .ipv4(.any)
        #if !os(Linux)
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = ipv6 ? .v6 : .v4
        #endif
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.allowLocalEndpointReuse = true
        let socket = NWConnection(to: server.address, using: parameters)
        let responses = AsyncStream<Mapping>.makeStream(bufferingPolicy: .bufferingNewest(1))
        @Sendable func read() {
            socket.receiveMessage { data, _, _, error in
                guard error == nil, let data else { responses.continuation.finish(); return }
                if let message = try? TURNMessage(data), message.id == id, message.type == 0x0101,
                   let mapped = try? message.address(.mapped), let ip = numericAddress(mapped),
                   mapped.ip.count == (ipv6 ? 16 : 4) {
                    let local = socket.currentPath?.localEndpoint.flatMap { ICEHostCandidate(observed: $0)?.address }
                    let related = local.flatMap(numericAddress) ?? (ipv6 ? "::" : "0.0.0.0")
                    let priority = 1_694_498_815 - index*256
                    let sdp = "candidate:\(32+index) 1 udp \(priority) \(ip) \(mapped.port) typ srflx raddr \(related) rport \(port.rawValue)"
                    responses.continuation.yield(.init(address: mapped, candidate: .init(addedSDP: sdp)))
                    responses.continuation.finish()
                } else { read() }
            }
        }
        socket.start(queue: .global(qos: .utility))
        read()
        let retransmit = Task {
            for interval in [250, 500, 1000, 2000] {
                try Task.checkCancellation()
                socket.send(content: request, completion: .idempotent)
                try await Task.sleep(for: .milliseconds(interval))
            }
            responses.continuation.finish()
        }
        defer {
            retransmit.cancel()
            responses.continuation.finish()
            socket.cancel()
        }
        for await mapping in responses.stream { return mapping }
        return nil
    }

    private static func numericAddress(_ address: ICEBinding.Address) -> String? {
        if address.ip.count == 4, let ip = IPv4Address(Data(address.ip)),
           ip != .any, ip != .broadcast, !ip.isMulticast { return ip.debugDescription }
        if address.ip.count == 16, let ip = IPv6Address(Data(address.ip)),
           ip != .any, !ip.isMulticast, !ip.isLinkLocal { return ip.debugDescription }
        return nil
    }
}

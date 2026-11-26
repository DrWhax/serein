#if os(Linux)
import Foundation
import Synchronization
import Testing
@testable import SwiftCalling

struct LinuxCallNetworkTests {
    @Test(arguments: ["127.0.0.1", "::1"])
    func nominatesInboundUDPAndExchangesMedia(address: String) async throws {
        let caller = DirectICETransport.Credentials(ufrag: "alice", password: String(repeating: "a", count: 32))
        let callee = DirectICETransport.Credentials(ufrag: "bobby", password: String(repeating: "b", count: 32))
        let incoming = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { incoming.continuation.finish() }
        let host = try await VoiceHostPort.gather(inbound: { conn in
            if case .dropped = incoming.continuation.yield(conn) { conn.cancel() }
        }, localAddresses: { [] })
        defer { host.close() }
        let local = try #require(ICEHostCandidate("candidate:1 1 udp 123 \(address) \(host.port.rawValue) typ host"))
        let payload = Data([128, 17, 42])
        let packets = Mutex<[Data]>([])
        let accept = Task {
            for await conn in incoming.stream {
                guard let candidate = ICEHostCandidate(observed: conn.endpoint) else { conn.cancel(); continue }
                do {
                    return try await DirectICETransport.accept(conn, candidate: candidate, local: callee, remote: caller,
                                                               role: .controlled(12)) { data in packets.withLock { $0.append(data) } }
                } catch { conn.cancel(); throw error }
            }
            throw CancellationError()
        }
        defer { accept.cancel() }
        let outbound = try await DirectICETransport.connect(route: .host(local), relayOnly: false, local: caller,
                                                            remote: callee, role: .controlling(13)) { data in
            packets.withLock { $0.append(data) }
        }
        defer { outbound.close() }
        let inbound = try await accept.value
        defer { inbound.close() }
        #expect(inbound.consented && outbound.consented)
        #expect(inbound.localHostEndpoint?.port == Int(host.port.rawValue))
        #expect(outbound.localHostEndpoint?.address == address)
        #expect(outbound.adapter == 16)
        try outbound.send(payload)
        try inbound.send(payload + Data([43]))
        let deadline = ContinuousClock.now + .seconds(2)
        while packets.withLock({ $0.count < 2 }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(packets.withLock { $0 }) == [payload, payload + Data([43])])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_STUN_ONLY"] == "1"))
    func stunUsesTheBoundMediaPort() async throws {
        let servicePort = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"])
        let host = try await VoiceHostPort.gather()
        defer { host.close() }
        let server = VoiceTURNServer(urls: ["stun:127.0.0.1:\(servicePort)"], username: "", password: "")
        let mappings = Mutex<[ICEBinding.Address]>([])
        await STUNDiscovery.gather(servers: [server], port: host.port) { mapping in
            mappings.withLock { $0.append(mapping.address) }
        }
        #expect(mappings.withLock { $0 } == [.init(ip: [127, 0, 0, 1], port: host.port.rawValue)])
    }

    @Test func cancelInterruptsPendingDatagramRead() async throws {
        let host = try await VoiceHostPort.gather(localAddresses: { [] })
        defer { host.close() }
        let conn = NWConnection(to: .hostPort(host: .init("127.0.0.1"), port: host.port), using: .udp)
        conn.start(queue: .global())
        let result = AsyncStream<Bool>.makeStream()
        conn.receiveMessage { _, _, _, error in
            result.continuation.yield(error != nil)
            result.continuation.finish()
        }
        try await Task.sleep(for: .milliseconds(30))
        conn.cancel()
        let timer = Task {
            try await Task.sleep(for: .seconds(1))
            result.continuation.finish()
        }
        defer { timer.cancel() }
        var iterator = result.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }
}
#endif

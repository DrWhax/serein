import Foundation
#if !os(Linux)
import Security
#endif
import Testing
@testable import SwiftCalling

enum TURNTestRelay {
    static var peerURI: String {
        let env = ProcessInfo.processInfo.environment
        // Tools/with-calling-turn.py's coturn when it set these, else the in-process Swift server.
        #if os(Linux)
        return env["SEREIN_TEST_TURN_URI"] ?? ""
        #else
        return env["SEREIN_TEST_TURN_URI"] ?? "turn:127.0.0.1:\(env["SEREIN_TEST_TURN_PORT"] ?? String(TURNTestServer.shared.port))?transport=udp"
        #endif
    }

    static func open(tlsHostname: String = "localhost", trustTestRoot: Bool = true) async throws -> TURNAllocation {
        let env = ProcessInfo.processInfo.environment
        var anchor: SecCertificate?
        let endpoint: TURNServerEndpoint
        if let port = env["SEREIN_TEST_TURN_TLS_PORT"] {
            endpoint = try #require(TURNServerEndpoint("turns:127.0.0.1:\(port)?transport=tcp", hostname: tlsHostname))
            if trustTestRoot {
                let file = try #require(env["SEREIN_TEST_TURN_CA"])
                let der = try Data(contentsOf: URL(fileURLWithPath: file))
                #if os(Linux)
                anchor = der
                #else
                anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
                #endif
            }
        } else { endpoint = try #require(TURNServerEndpoint(peerURI)) }
        return try await TURNAllocation.open(server: endpoint, username: "serein", password: "serein-test-relay", trustAnchor: anchor)
    }
}

struct TURNStreamTests {
    @Test func transportAndHost() throws {
        for (uri, expected, port) in [
            ("turn:relay.example", TURNClientTransport.udp, 3478), ("turn:relay.example.?transport=TCP", .tcp, 3478),
            ("turn:[2001:db8::1]:234?transport=tcp", .tcp, 234), ("turns:relay.example", .tls, 5349),
            ("turns:192.0.2.1:443?transport=tcp", .tls, 443)
        ] {
            let server = try #require(TURNServerEndpoint(uri, hostname: "relay.example"))
            #expect(server.transport == expected)
            #expect(Int(server.port.rawValue) == port)
            #expect(server.tlsHostname == (expected == .tls ? "relay.example" : nil))
        }
        for uri in ["turns:relay?transport=udp", "turn:host:0", "turn:host:65536", "turn:host:", "turn:[::1]x",
                    "turn:2001:db8::1", "turn:user@host", "turn:host/", "turn:host#fragment", "turn:host?",
                    "turn:host?transport=tcp&foo=bar", "turn://relay", "turn:.example", "turn:[fe80::1%en0]"] {
            #expect(TURNServerEndpoint(uri) == nil)
        }
        #expect(TURNServerEndpoint("turns:192.0.2.1", hostname: "a/b") == nil)
    }

    @Test func fragmentedAndCoalescedMessages() throws {
        let a = try TURNMessage.packet(0x103, id: TURNMessage.newID(), attributes: [(.data, [1, 2, 3])])
        let b = try TURNMessage.packet(0x117, id: TURNMessage.newID(), attributes: [])
        // An unbound channel frame has one data byte and three padding bytes.
        let wire = a + Data([0x40, 2, 0, 1, 42, 0, 0, 0]) + b
        for split in 0...wire.count {
            var framer = TURNStreamFramer()
            let first = try framer.append(wire.prefix(split))
            #expect(try first + framer.append(wire.suffix(from: split)) == [a, b])
        }
        var framer = TURNStreamFramer()
        for fragment in [Data([0x80, 0, 0, 0]), Data([0, 1, 0, 1]), Data([0, 1, 0, 0, 1, 2, 3, 4])] {
            framer = TURNStreamFramer()
            #expect(throws: TURNMessage.Failure.self) { try framer.append(fragment) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_TLS_PORT"] != nil))
    func rejectsUntrustedAndWrongName() async {
        // This certificate identity has no DNS record. The numeric Signal URL must work.
        do { let ipRoute = try await TURNTestRelay.open(tlsHostname: "relay.invalid"); ipRoute.close() }
        catch { Issue.record("TLS on the supplied IP with a separate certificate name failed: \(error)") }
        await #expect(throws: TURNMessage.Failure.self) { try await TURNTestRelay.open(trustTestRoot: false) }
        await #expect(throws: TURNMessage.Failure.self) { try await TURNTestRelay.open(tlsHostname: "127.0.0.1") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_URI"]?.hasSuffix("transport=tcp") == true))
    func triesTCPWhenUDPIsFiltered() async throws {
        let tcp = TURNTestRelay.peerURI
        let start = ContinuousClock.now
        let config = VoiceTURNServer(urls: [tcp.replacingOccurrences(of: "transport=tcp", with: "transport=udp"), tcp],
                                      username: "serein", password: "serein-test-relay")
        let allocation = try #require(await VoiceTURNServer.allocateFirst([config]))
        defer { allocation.close() }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}

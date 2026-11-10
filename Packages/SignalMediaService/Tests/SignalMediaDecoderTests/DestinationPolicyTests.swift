// The link-preview fetcher's destination policy (WebFetch/DestinationPolicy.swift): only
// public unicast addresses, for IP literals and for every address a name resolves to.

import Foundation
import Testing
@testable import WebFetch

@Suite struct DestinationPolicyTests {
    @Test(arguments: ["93.184.216.34", "8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1", "192.169.0.1",
                      "2606:4700:4700::1111", "2a00:1450:4001:82a::200e", "64:ff9b::808:808"])
    func publicAddresses(_ a: String) { #expect(PublicAddress.isPublic(a)) }

    @Test(arguments: ["0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                      "192.0.0.8", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.51.100.7", "203.0.113.9", "224.0.0.1", "239.255.255.250",
                      "255.255.255.255", "::", "::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "fc00::1", "fd12:3456::1", "fe80::1", "fe80::1%en0",
                      "fec0::1", "ff02::1", "2001::1", "2001:db8::1", "2002:c0a8:101::1", "3fff::1", "64:ff9b::a00:1", "not an address", ""])
    func nonPublicAddresses(_ a: String) { #expect(!PublicAddress.isPublic(a)) }

    struct Recorder: WebTransport {
        func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
            WebResponse(status: 200, headers: [:], body: Data("ok".utf8), url: url)
        }
    }

    @Test func refusesHostsOffThePublicInternet() async throws {
        let resolver: @Sendable (String) async -> [String] = { host in
            switch host {
            case "public.example": return ["93.184.216.34", "2606:2800:220:1::1"]
            case "router.example": return ["192.168.1.1"]
            case "mixed.example": return ["93.184.216.34", "10.0.0.1"]   // one private answer is enough
            default: return []
            }
        }
        let t = PublicDestinationTransport(Recorder(), resolve: resolver)
        #expect(try await t.get(URL(string: "https://public.example/")!, headers: [:], limit: 10).status == 200)
        #expect(try await t.get(URL(string: "https://8.8.8.8/")!, headers: [:], limit: 10).status == 200)
        for href in ["https://router.example/", "https://mixed.example/", "https://unknown.example/", "https://192.168.1.1/admin",
                     "https://10.0.0.1/", "https://[::1]/", "https://[fe80::1]/", "https://127.0.0.1:8443/"] {
            await #expect(throws: WebError.forbiddenDestination, "\(href)") { try await t.get(URL(string: href)!, headers: [:], limit: 10) }
        }
    }

    @Test func systemResolverFindsAddresses() async {
        // localhost resolves on every machine, and is refused.
        let addresses = await PublicDestinationTransport.systemResolve("localhost")
        #expect(!addresses.isEmpty && !addresses.contains(where: PublicAddress.isPublic))
    }
}

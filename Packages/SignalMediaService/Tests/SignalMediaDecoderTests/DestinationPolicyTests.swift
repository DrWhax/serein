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

    /// Answers as if its connection reached `reached` (nil: not reported).
    struct Recorder: WebTransport {
        var reached: [String]? = ["93.184.216.34"]
        func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
            WebResponse(status: 200, headers: [:], body: Data("ok".utf8), url: url, remoteAddresses: reached)
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
                     "https://10.0.0.1/", "https://[::1]/", "https://[fe80::1]/", "https://127.0.0.1:8443/",
                     // Only https's own port.
                     "https://public.example:8443/", "https://8.8.8.8:22/"] {
            await #expect(throws: WebError.forbiddenDestination, "\(href)") { try await t.get(URL(string: href)!, headers: [:], limit: 10) }
        }
        #expect(try await t.get(URL(string: "https://public.example:443/")!, headers: [:], limit: 10).status == 200)
    }

    /// The name checked out, but the connection went elsewhere (a DNS answer that changed in
    /// between): the response is refused, as is one whose connections were not reported.
    @Test func refusesWhatAReboundConnectionAnswered() async throws {
        let resolver: @Sendable (String) async -> [String] = { _ in ["93.184.216.34"] }
        let url = URL(string: "https://public.example/")!
        for reached: [String]? in [["192.168.1.1"], ["93.184.216.34", "10.0.0.1"], ["::1"], [""], [], nil] {
            let t = PublicDestinationTransport(Recorder(reached: reached), resolve: resolver)
            await #expect(throws: WebError.forbiddenDestination, "\(String(describing: reached))") { try await t.get(url, headers: [:], limit: 10) }
        }
        let fine = PublicDestinationTransport(Recorder(reached: ["93.184.216.34", "2606:2800:220:1::1"]), resolve: resolver)
        #expect(try await fine.get(url, headers: [:], limit: 10).status == 200)
    }

    /// The transport's hand-off of a task's addresses: delivered before or after the wait, once
    /// (a later delivery is dropped), and none if they never come.
    @Test func metricsReachTheirRequest() async {
        let d = WebSessionDelegate(rootsDER: [])
        d.deliver(1, ["93.184.216.34"])
        #expect(await d.addresses(1, timeout: .seconds(5)) == ["93.184.216.34"])
        async let later = d.addresses(2, timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        d.deliver(2, ["10.0.0.1"])
        d.deliver(2, ["93.184.216.34"])
        #expect(await later == ["10.0.0.1"])
        #expect(await d.addresses(3, timeout: .milliseconds(50)) == [])
    }

    @Test func systemResolverFindsAddresses() async {
        // localhost resolves on every machine, and is refused.
        let addresses = await PublicDestinationTransport.systemResolve("localhost")
        #expect(!addresses.isEmpty && !addresses.contains(where: PublicAddress.isPublic))
    }
}

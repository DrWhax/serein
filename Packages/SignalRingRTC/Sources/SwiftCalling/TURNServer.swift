import Foundation
import Network

/// The transport from Serein to the TURN server. The requested peer-facing allocation is UDP.
enum TURNClientTransport: Hashable, Sendable { case udp, tcp, tls }

struct TURNServerEndpoint: Sendable {
    let host: String
    let port: NWEndpoint.Port
    let transport: TURNClientTransport
    let tlsHostname: String?

    var address: NWEndpoint { .hostPort(host: .init(host), port: port) }

    /// Parse Signal's RFC 7065 URIs. A turns URI can only produce a TLS connection.
    init?(_ uri: String, hostname: String = "") {
        self.init(uri, hostname: hostname, bindingDiscovery: false)
    }

    /// A UDP STUN Binding request discovers the address of the local UDP media
    /// socket. A TCP or TLS mapping belongs to the server connection instead.
    init?(stunURI uri: String) {
        self.init(uri, hostname: "", bindingDiscovery: true)
    }

    private init?(_ uri: String, hostname: String, bindingDiscovery: Bool) {
        guard uri.utf8.count <= 2048, let colon = uri.firstIndex(of: ":") else { return nil }
        let scheme = uri[..<colon].lowercased()
        guard scheme == "turn" || scheme == "turns" || (bindingDiscovery && scheme == "stun") else { return nil }
        let parts = uri[uri.index(after: colon)...].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let authority = parts.first, !authority.isEmpty else { return nil }
        let query = parts.count == 2 ? parts[1].lowercased() : nil
        switch (scheme, query) {
        case ("stun", nil), ("turn", nil), ("turn", "transport=udp"): transport = .udp
        case ("turn", "transport=tcp"): transport = .tcp
        case ("turns", nil), ("turns", "transport=tcp"): transport = .tls
        default: return nil
        }

        guard !bindingDiscovery || transport == .udp else { return nil }

        var portText: Substring?
        if authority.first == "[" {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            let literal = String(authority[authority.index(after: authority.startIndex)..<end])
            guard !literal.contains("%"), IPv6Address(literal) != nil else { return nil }
            host = literal
            let tail = authority[authority.index(after: end)...]
            if !tail.isEmpty {
                guard tail.first == ":" else { return nil }
                portText = tail.dropFirst()
            }
        } else {
            let fields = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = fields.first, Self.validName(first) else { return nil }
            host = String(first)
            if fields.count == 2 { portText = fields[1] }
        }
        var number: UInt16 = scheme == "turns" ? 5349 : 3478
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let explicit = UInt16(portText), explicit > 0 else { return nil }
            number = explicit
        }
        guard let port = NWEndpoint.Port(rawValue: number) else { return nil }
        self.port = port
        if transport == .tls, !hostname.isEmpty {
            guard Self.validName(hostname[...]) else { return nil }
            tlsHostname = hostname
        } else { tlsHostname = nil }
    }

    private static func validName(_ value: Substring) -> Bool {
        let name = value.last == "." ? value.dropLast() : value
        return (1...253).contains(name.utf8.count) && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }
    }
}

package struct VoiceTURNServer: Sendable {
    let urls: [String]
    let username: String
    let password: String
    let hostname: String

    package init(urls: [String], username: String, password: String, hostname: String = "") {
        self.urls = urls
        self.username = username
        self.password = password
        self.hostname = hostname
    }

    /// Try each transport independently so filtered UDP cannot consume the ICE setup deadline.
    /// Keep server preference within each transport and close allocations from losing attempts.
    static func allocateFirst(_ servers: [Self]) async -> TURNAllocation? {
        struct Candidate: Sendable {
            let server: VoiceTURNServer
            let endpoint: TURNServerEndpoint
        }
        var lanes: [[Candidate]] = []
        for server in servers.prefix(16) {
            for url in server.urls.prefix(16) {
                guard let endpoint = TURNServerEndpoint(url, hostname: server.hostname) else { continue }
                let candidate = Candidate(server: server, endpoint: endpoint)
                if let index = lanes.firstIndex(where: { $0.first?.endpoint.transport == endpoint.transport }) {
                    lanes[index].append(candidate)
                } else { lanes.append([candidate]) }
            }
        }
        return await withTaskGroup(of: TURNAllocation?.self) { group in
            for (index, lane) in lanes.enumerated() {
                group.addTask {
                    if index != 0 {
                        do { try await Task.sleep(for: .milliseconds(250 * index)) } catch { return nil }
                    }
                    for candidate in lane {
                        if Task.isCancelled { return nil }
                        if let allocation = try? await TURNAllocation.open(server: candidate.endpoint,
                                username: candidate.server.username, password: candidate.server.password) {
                            return allocation
                        }
                    }
                    return nil
                }
            }
            var winner: TURNAllocation?
            for await result in group {
                guard let result else { continue }
                if winner == nil && !Task.isCancelled { winner = result; group.cancelAll() }
                else { result.close() }
            }
            return winner
        }
    }
}

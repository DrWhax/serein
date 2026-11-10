// Where SignalLinkPreviewFetcher.xpc may connect: only to addresses on the public internet.
// Upstream Desktop previews any https link whose host passes isLinkSneaky, IP literals and
// names that resolve into the local network included; Serein refuses those, so a pasted link
// (or a redirect it leads to) cannot make the fetcher send requests to a router, printer or
// other machine on the user's network. (Its Seatbelt profile already keeps it off this
// machine's own ports.)
//
// Each hop's host is resolved here, and refused if it has no address or any address that is
// not public. URLSession then resolves the name again for its own connection, so a DNS answer
// that changes in between (rebinding) is not caught by this check.

import Foundation
import Network

public enum PublicAddress {
    /// True only for unicast addresses that are routed on the public internet.
    public static func isPublic(_ address: String) -> Bool {
        if let v4 = IPv4Address(address) { return isPublic(v4: [UInt8](v4.rawValue)) }
        if !address.contains("%"), let v6 = IPv6Address(address) { return isPublic(v6: [UInt8](v6.rawValue)) }
        return false   // unparseable, or IPv6 with a zone (link-local)
    }

    /// RFC 6890 and the IANA special-purpose registry: everything but global unicast.
    static func isPublic(v4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let (a, c) = (b[0], b[1])
        switch a {
        case 0, 10, 127: return false                                   // this network, private, loopback
        case 100 where (64...127).contains(c): return false             // shared address space (CGNAT)
        case 169 where c == 254: return false                           // link-local
        case 172 where (16...31).contains(c): return false              // private
        case 192 where c == 168: return false                           // private
        case 192 where c == 0 && (b[2] == 0 || b[2] == 2): return false  // IETF protocol assignments, TEST-NET-1
        case 192 where c == 88 && b[2] == 99: return false              // 6to4 relay anycast
        case 198 where c == 18 || c == 19: return false                 // benchmarking
        case 198 where c == 51 && b[2] == 100: return false             // TEST-NET-2
        case 203 where c == 0 && b[2] == 113: return false              // TEST-NET-3
        case 224...255: return false                                    // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublic(v6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // NAT64 (64:ff9b::/96): judged by the IPv4 address it carries (IPv6-only networks).
        if b[0...11].elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) { return isPublic(v4: Array(b[12...15])) }
        // Global unicast is 2000::/3; within it, refuse the special-purpose blocks.
        guard b[0] & 0xE0 == 0x20 else { return false }   // also ::, ::1, mapped v4, fc00::/7, fe80::/10, ff00::/8
        if b[0] == 0x20 && b[1] == 0x01 {
            if b[2] < 0x02 { return false }                       // 2001::/23 IETF protocol assignments (Teredo, ORCHID, ...)
            if b[2] == 0x0D && b[3] == 0xB8 { return false }      // 2001:db8::/32 documentation
        }
        if b[0] == 0x20 && b[1] == 0x02 { return false }          // 2002::/16 6to4
        if b[0] == 0x3F && b[1] == 0xFF && b[2] & 0xF0 == 0 { return false }   // 3fff::/20 documentation
        return true
    }
}

/// A transport that refuses any URL whose host is not on the public internet (see above).
public struct PublicDestinationTransport: WebTransport {
    let base: any WebTransport
    let resolve: @Sendable (String) async -> [String]

    /// `resolve` (tests) replaces the system resolver.
    public init(_ base: any WebTransport, resolve: (@Sendable (String) async -> [String])? = nil) {
        self.base = base
        self.resolve = resolve ?? Self.systemResolve
    }

    public func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { throw WebError.forbiddenDestination }
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let addresses = IPv4Address(literal) != nil || IPv6Address(literal) != nil ? [literal] : await resolve(host)
        guard !addresses.isEmpty, addresses.allSatisfy(PublicAddress.isPublic) else { throw WebError.forbiddenDestination }
        return try await base.request(method, url, headers: headers, limit: limit)
    }

    /// Every address the system resolver has for `host` (NSHost, which no longer caches),
    /// off the cooperative threads (the lookup blocks).
    static let systemResolve: @Sendable (String) async -> [String] = { host in
        await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                k.resume(returning: Host(name: host).addresses)
            }
        }
    }
}

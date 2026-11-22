import Network

/// Report the WebRTC adapter flags used at Serein's calling API boundary.
struct CallNetworkPath: Equatable, Sendable {
    let usable: Bool
    let adapter: Int
    let interfaces: [String]
    let ipv4: Bool
    let ipv6: Bool

    init(_ path: NWPath) {
        usable = path.status == .satisfied
        let active = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
        interfaces = active.map(\.name).sorted()
        ipv4 = path.supportsIPv4
        ipv6 = path.supportsIPv6
        if active.contains(where: { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ppp") }) { adapter = 8 }
        else if path.usesInterfaceType(.wiredEthernet) { adapter = 1 }
        else if path.usesInterfaceType(.wifi) { adapter = 2 }
        else if path.usesInterfaceType(.cellular) { adapter = 4 }
        else if path.usesInterfaceType(.loopback) { adapter = 16 }
        else { adapter = usable ? 32 : 0 }
    }
}

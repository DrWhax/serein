#if os(Linux)
import CLinuxCallNetwork
import Foundation
import Synchronization

private func packedIP(_ address: String) -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    var buffer = bytes.mutableSpan
    let n = call_net_parse_ip(Array(address.utf8).span, &buffer)
    return Data(bytes.prefix(Int(n)))
}

private func formatIP(_ raw: Data) -> String {
    var text = [UInt8](repeating: 0, count: 46)
    var buffer = text.mutableSpan
    let n = call_net_format_ip(Array(raw).span, &buffer)
    return String(decoding: text.prefix(Int(n)), as: UTF8.self)
}

struct IPv4Address: Hashable, Sendable {
    let rawValue: Data
    init?(_ data: Data) { guard data.count == 4 else { return nil }; rawValue = data }
    init?(_ address: String) { self.init(packedIP(address)) }
    static let any = Self(Data(repeating: 0, count: 4))!
    static let broadcast = Self(Data(repeating: 255, count: 4))!
    var isLoopback: Bool { rawValue.first == 127 }
    var isLinkLocal: Bool { rawValue.starts(with: [169, 254]) }
    var isMulticast: Bool { rawValue.first.map { (224..<240).contains($0) } == true }
    var debugDescription: String { formatIP(rawValue) }
}

struct IPv6Address: Hashable, Sendable {
    let rawValue: Data
    init?(_ data: Data) { guard data.count == 16 else { return nil }; rawValue = data }
    init?(_ address: String) { self.init(packedIP(address)) }
    static let any = Self(Data(repeating: 0, count: 16))!
    var isLoopback: Bool { rawValue.dropLast().allSatisfy { $0 == 0 } && rawValue.last == 1 }
    var isLinkLocal: Bool { rawValue.first == 0xfe && rawValue.dropFirst().first.map { $0 & 0xc0 == 0x80 } == true }
    var isMulticast: Bool { rawValue.first == 255 }
    var asIPv4: IPv4Address? {
        guard rawValue.prefix(10).allSatisfy({ $0 == 0 }), rawValue.dropFirst(10).starts(with: [255, 255]) else { return nil }
        return IPv4Address(Data(rawValue.suffix(4)))
    }
    var debugDescription: String { formatIP(rawValue) }
}

enum NWEndpoint: Sendable, Hashable {
    struct Port: RawRepresentable, Hashable, Sendable {
        let rawValue: UInt16
        init?(rawValue: UInt16) { self.rawValue = rawValue }
    }
    enum Host: Hashable, Sendable {
        case ipv4(IPv4Address), ipv6(IPv6Address), name(String)
        init(_ name: String) {
            if let v4 = IPv4Address(name) { self = .ipv4(v4) }
            else if let v6 = IPv6Address(name) { self = .ipv6(v6) }
            else { self = .name(name) }
        }
        var text: String {
            switch self {
            case .ipv4(let ip): ip.debugDescription
            case .ipv6(let ip): ip.debugDescription
            case .name(let name): name
            }
        }
    }
    case hostPort(host: Host, port: Port)

    init?(bytes: Data, port: UInt16) {
        guard let port = Port(rawValue: port) else { return nil }
        if let v4 = IPv4Address(bytes) { self = .hostPort(host: .ipv4(v4), port: port) }
        else if let v6 = IPv6Address(bytes) { self = .hostPort(host: .ipv6(v6), port: port) }
        else { return nil }
    }
}

struct NWPath: Equatable, Sendable {
    enum Status { case satisfied, unsatisfied }
    struct Interface: Equatable, Sendable {
        enum Kind: String { case wiredEthernet = "ethernet", wifi, cellular, loopback, vpn, other }
        let name: String
        let type: Kind
    }
    let availableInterfaces: [Interface]
    let localEndpoint: NWEndpoint?
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    var status: Status { availableInterfaces.isEmpty ? .unsatisfied : .satisfied }
    func usesInterfaceType(_ type: Interface.Kind) -> Bool { availableInterfaces.contains { $0.type == type } }

    private struct Address {
        let interface: Interface
        let ip: String
        let routed: Bool
    }
    private static func interfaceAddresses() -> [Address] {
        var bytes = [UInt8](repeating: 0, count: 2048)
        var size: Int
        repeat {
            var buffer = bytes.mutableSpan
            size = Int(call_net_interfaces(&buffer))
            if size <= bytes.count { break }
            bytes = [UInt8](repeating: 0, count: size)
        } while true
        return String(decoding: bytes.prefix(max(0, size)), as: UTF8.self).split(separator: "\n").compactMap { line in
            let row = line.split(separator: "\t")
            guard row.count == 4, let kind = Interface.Kind(rawValue: String(row[2])) else { return nil }
            return Address(interface: Interface(name: String(row[0]), type: kind), ip: String(row[1]), routed: row[3] == "1")
        }
    }
    static var localAddresses: [String] { interfaceAddresses().map(\.ip) }

    init(local: NWEndpoint? = nil) {
        localEndpoint = local
        let address: String?
        if case .hostPort(let host, _) = local { address = host.text } else { address = nil }
        var interfaces = [Interface](), v4 = false, v6 = false
        for row in Self.interfaceAddresses() where address.map({ $0 == row.ip }) ?? row.routed {
            if !interfaces.contains(row.interface) { interfaces.append(row.interface) }
            if row.ip.contains(":") { v6 = true } else { v4 = true }
        }
        availableInterfaces = interfaces.sorted { $0.name < $1.name }
        supportsIPv4 = v4
        supportsIPv6 = v6
    }
}

final class NWPathMonitor: Sendable {
    private let monitor = Mutex<Task<Void, Never>?>(nil)
    private let handler = Mutex<(@Sendable (NWPath) -> Void)?>(nil)
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }
    func start(queue: DispatchQueue) {
        let task = Task.detached(priority: .utility) { [weak self] in
            var last: NWPath?
            while !Task.isCancelled {
                let path = NWPath()
                if path != last {
                    last = path
                    queue.async { [weak self] in self?.pathUpdateHandler?(path) }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        monitor.withLock { $0?.cancel(); $0 = task }
    }
    func cancel() { monitor.withLock { $0?.cancel(); $0 = nil } }
    deinit { cancel() }
}
#endif

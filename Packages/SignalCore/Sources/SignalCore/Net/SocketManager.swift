// Chat-service transport on libsignal-net (port of Desktop's SocketManager.preload.ts
// for the parts SignalCore needs): one unauthenticated and one authenticated
// chat connection, REST-over-WebSocket requests, and automatic reconnection of the
// authenticated socket that delivers incoming envelopes.

import Foundation
import LibSignalClient

public struct ChatCredentials: Sendable {
    public var username: String   // "<aci>.<deviceId>"
    public var password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum ChatRequestError: Error, Equatable {
    case http(status: UInt16, message: String, body: Data)
    case notConnected

    public var status: UInt16? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }
}

final class NoopUnauthenticatedListener: ConnectionEventsListener {
    func connectionWasInterrupted(_ service: UnauthenticatedChatConnection, error: Error?) {}
}

public actor SocketManager {
    let net: Net
    var credentials: ChatCredentials?
    var unauthenticated: UnauthenticatedChatConnection?
    var authenticated: AuthenticatedChatConnection?
    weak var listener: (any ChatConnectionListener)?
    var reconnectTask: Task<Void, Never>?
    var stopped = false

    public init(net: Net, credentials: ChatCredentials? = nil) {
        self.net = net
        self.credentials = credentials
    }

    public func setCredentials(_ c: ChatCredentials) { credentials = c }

    // MARK: unauthenticated

    func unauthenticatedConnection() async throws -> UnauthenticatedChatConnection {
        if let c = unauthenticated { return c }
        let c = try await net.connectUnauthenticatedChat()
        c.start(listener: NoopUnauthenticatedListener())
        unauthenticated = c
        return c
    }

    /// REST request over the unauthenticated chat socket (optionally with explicit
    /// Basic auth, as `PUT /v1/devices/link` needs).
    public func unauthenticatedRequest(_ method: String, _ path: String, json: Data? = nil, basicAuth: (String, String)? = nil,
                                       headers extra: [String: String] = [:]) async throws -> Data {
        var headers = extra
        if json != nil { headers["content-type"] = "application/json" }
        if let (u, p) = basicAuth { headers["authorization"] = "Basic " + Data("\(u):\(p)".utf8).base64EncodedString() }
        let response = try await unauthenticatedConnection().send(ChatRequest(method: method, pathAndQuery: path, headers: headers, body: json, timeout: 30))
        return try Self.check(response)
    }

    // MARK: authenticated

    /// Connects (or returns) the authenticated socket; incoming envelopes go to `listener`.
    public func connect(listener: any ChatConnectionListener) async throws {
        self.listener = listener
        stopped = false
        if authenticated == nil { try await connectAuthenticated() }
    }

    func connectAuthenticated() async throws {
        guard let c = credentials, let l = listener else { throw ChatRequestError.notConnected }
        let chat = try await net.connectAuthenticatedChat(username: c.username, password: c.password, receiveStories: true)
        chat.start(listener: ReconnectingListener(inner: l, manager: self))
        authenticated = chat
    }

    nonisolated func connectionInterrupted() {
        Task { await self.scheduleReconnect() }
    }

    func scheduleReconnect() {
        authenticated = nil
        guard !stopped, reconnectTask == nil else { return }
        reconnectTask = Task {
            var delay: UInt64 = 250_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                if self.stopped { break }
                do {
                    try await self.connectAuthenticated()
                    break
                } catch {
                    delay = min(delay * 2, 30_000_000_000)
                }
            }
            self.reconnectTask = nil
        }
    }


    public func authenticatedRequest(_ method: String, _ path: String, json: Data? = nil) async throws -> Data {
        guard let chat = authenticated else { throw ChatRequestError.notConnected }
        let response = try await chat.send(ChatRequest(method: method, pathAndQuery: path,
                                                       headers: json == nil ? [:] : ["content-type": "application/json"],
                                                       body: json, timeout: 30))
        return try Self.check(response)
    }

    public func disconnect() async {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        try? await authenticated?.disconnect()
        try? await unauthenticated?.disconnect()
        authenticated = nil
        unauthenticated = nil
    }

    static func check(_ r: ChatResponse) throws -> Data {
        guard (200..<300).contains(r.status) else { throw ChatRequestError.http(status: r.status, message: r.message, body: r.body) }
        return r.body
    }
}

/// Forwards events and triggers reconnection when the socket drops.
final class ReconnectingListener: ChatConnectionListener, @unchecked Sendable {
    let inner: any ChatConnectionListener
    let manager: SocketManager
    init(inner: any ChatConnectionListener, manager: SocketManager) {
        self.inner = inner
        self.manager = manager
    }
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                        sendAck: @escaping () throws -> Void) {
        inner.chatConnection(chat, didReceiveIncomingMessage: envelope, serverDeliveryTimestamp: serverDeliveryTimestamp, sendAck: sendAck)
    }
    func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) { inner.chatConnectionDidReceiveQueueEmpty(chat) }
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveAlerts alerts: [String]) { inner.chatConnection(chat, didReceiveAlerts: alerts) }
    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {
        inner.connectionWasInterrupted(service, error: error)
        manager.connectionInterrupted()
    }
}

// `Net` only holds native handles (Tokio context + connection manager) that the
// Rust side synchronises internally; Signal-iOS shares one instance across tasks.
extension Net: @retroactive @unchecked Sendable {}

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

/// Tells the manager when its unauthenticated connection closes, so the next request opens a
/// new one (upstream SocketManager drops its unauthenticated socket on close). Before, a dropped
/// connection stayed cached and every sealed-sender and group send failed until a restart.
final class UnauthenticatedInterruptionListener: ConnectionEventsListener, Sendable {
    weak let manager: SocketManager?
    init(manager: SocketManager) { self.manager = manager }
    func connectionWasInterrupted(_ service: UnauthenticatedChatConnection, error: Error?) {
        manager?.unauthenticatedInterrupted(service)
    }
}

public actor SocketManager {
    let net: Net
    var credentials: ChatCredentials?
    var unauthenticated: UnauthenticatedChatConnection?
    var authenticated: AuthenticatedChatConnection?
    weak var listener: (any ChatConnectionListener & Sendable)?
    var reconnectTask: Task<Void, Never>?
    /// The current reconnect task's number: a superseded task does not clear its successor.
    var reconnectGeneration = 0
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
        c.start(listener: UnauthenticatedInterruptionListener(manager: self))
        unauthenticated = c
        return c
    }

    nonisolated func unauthenticatedInterrupted(_ c: UnauthenticatedChatConnection) {
        Task { await self.dropUnauthenticated(c) }
    }

    func dropUnauthenticated(_ c: UnauthenticatedChatConnection) {
        if unauthenticated === c { unauthenticated = nil }
    }

    /// `body` on the unauthenticated connection. One found closed (its interruption not handled
    /// yet) is replaced and `body` runs once more: the request never left.
    func withUnauthenticated<T: Sendable>(_ body: (UnauthenticatedChatConnection) async throws -> T) async throws -> T {
        let chat = try await unauthenticatedConnection()
        do {
            return try await body(chat)
        } catch SignalError.chatServiceInactive {
            dropUnauthenticated(chat)
            return try await body(try await unauthenticatedConnection())
        }
    }

    /// `body` on the authenticated connection. One found closed without its interruption having
    /// reached us is replaced as an interruption would (reconnect with backoff); the request
    /// fails as not connected, and the job that sent it retries.
    func withAuthenticated<T: Sendable>(_ body: (AuthenticatedChatConnection) async throws -> T) async throws -> T {
        guard let chat = authenticated else { throw ChatRequestError.notConnected }
        do {
            return try await body(chat)
        } catch SignalError.chatServiceInactive {
            if authenticated === chat { scheduleReconnect() }
            throw ChatRequestError.notConnected
        }
    }

    /// REST request over the unauthenticated chat socket (optionally with explicit
    /// Basic auth, as `PUT /v1/devices/link` needs).
    public func unauthenticatedRequest(_ method: String, _ path: String, json: Data? = nil, basicAuth: (String, String)? = nil,
                                       headers extra: [String: String] = [:], authorize: @Sendable () throws -> Void = {}) async throws -> Data {
        var headers = extra
        if json != nil { headers["content-type"] = "application/json" }
        if let (u, p) = basicAuth { headers["authorization"] = "Basic " + Data("\(u):\(p)".utf8).base64EncodedString() }
        let response = try await withUnauthenticated { chat in
            try Task.checkCancellation()
            try authorize()
            return try await chat.send(ChatRequest(method: method, pathAndQuery: path, headers: headers, body: json, timeout: 30))
        }
        return try Self.check(response)
    }

    // MARK: authenticated

    /// Connects (or returns) the authenticated socket; incoming envelopes go to `listener`.
    /// A failure (offline at launch, the server unreachable) leaves the manager reconnecting in
    /// the background, as after an interruption; before, nothing retried until a restart.
    public func connect(listener: any ChatConnectionListener & Sendable) async throws {
        self.listener = listener
        stopped = false
        guard authenticated == nil else { return }
        do {
            try await connectAuthenticated()
        } catch {
            scheduleReconnect()
            throw error
        }
    }

    func connectAuthenticated() async throws {
        guard let c = credentials, let l = listener else { throw ChatRequestError.notConnected }
        let chat = try await net.connectAuthenticatedChat(username: c.username, password: c.password, receiveStories: true)
        // A reconnect superseded while it was connecting (reconnectNow) leaves its connection.
        if Task.isCancelled {
            try? await chat.disconnect()
            throw CancellationError()
        }
        chat.start(listener: ReconnectingListener(inner: l, manager: self))
        authenticated = chat
    }

    nonisolated func connectionInterrupted(_ chat: AuthenticatedChatConnection) {
        Task { await self.interrupted(chat) }
    }

    /// The connection dropped: reconnect, unless it was already replaced (a replaced
    /// connection's late interruption would otherwise drop its successor).
    func interrupted(_ chat: AuthenticatedChatConnection) {
        guard authenticated === chat else { return }
        scheduleReconnect()
    }

    /// Reconnects in the background with backoff (250 ms doubling to 30 s), or at once first
    /// (`immediately`).
    func scheduleReconnect(immediately: Bool = false) {
        authenticated = nil
        guard !stopped, reconnectTask == nil else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task {
            var delay: UInt64 = immediately ? 0 : 250_000_000
            while !Task.isCancelled {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                if self.stopped || Task.isCancelled { break }
                do {
                    try await self.connectAuthenticated()
                    break
                } catch {
                    delay = max(250_000_000, min(delay * 2, 30_000_000_000))
                }
            }
            if self.reconnectGeneration == generation { self.reconnectTask = nil }
        }
    }

    /// The Mac woke or the network changed: the connections, which may have died unnoticed, are
    /// replaced now, and a reconnect waiting out its backoff goes at once instead of up to 30 s
    /// later. (The unauthenticated one reopens at its next request.)
    public func reconnectNow() {
        guard !stopped, credentials != nil, listener != nil else { return }
        if let u = unauthenticated {
            unauthenticated = nil
            Task { try? await u.disconnect() }
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        if let a = authenticated { Task { try? await a.disconnect() } }
        scheduleReconnect(immediately: true)
    }


    public func authenticatedRequest(_ method: String, _ path: String, json: Data? = nil, authorize: @Sendable () throws -> Void = {}) async throws -> Data {
        let response = try await withAuthenticated { chat in
            try Task.checkCancellation()
            try authorize()
            return try await chat.send(ChatRequest(method: method, pathAndQuery: path,
                                                   headers: json == nil ? [:] : ["content-type": "application/json"],
                                                   body: json, timeout: 30))
        }
        return try Self.check(response)
    }

    /// `getAttachmentUploadForm` (libsignal's typed Attachments/GetUploadForm).
    public func uploadForm(size: Int) async throws -> UploadForm {
        try await withAuthenticated { chat in try await chat.getUploadForm(uploadSize: UInt64(size)) }
    }

    /// `sendMulti` (MessagesAnonymous/SendMultiRecipientMessage): a sealed-sender multi-recipient
    /// payload authorised by a group send token.
    public func sendMultiRecipient(_ payload: Data, timestamp: UInt64, token: Data, online: Bool, urgent: Bool,
                                   authorize: @Sendable () throws -> Void = {}) async throws -> [ServiceId] {
        let response = try await withUnauthenticated { chat in
            try Task.checkCancellation()
            try authorize()
            return try await chat.sendMultiRecipientMessage(
                payload, timestamp: timestamp, auth: .groupSend(try GroupSendFullToken(contents: token)), onlineOnly: online, urgent: urgent)
        }
        return response.unregisteredIds
    }

    /// The raw response (any status), for requests that use headers such as ETags.
    public func authenticatedResponse(_ method: String, _ path: String, headers: [String: String] = [:], json: Data? = nil) async throws
        -> ChatResponse
    {
        var h = headers
        if json != nil { h["content-type"] = "application/json" }
        let request = ChatRequest(method: method, pathAndQuery: path, headers: h, body: json, timeout: 30)
        return try await withAuthenticated { chat in try await chat.send(request) }
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
final class ReconnectingListener: ChatConnectionListener, Sendable {
    let inner: any ChatConnectionListener & Sendable
    let manager: SocketManager
    init(inner: any ChatConnectionListener & Sendable, manager: SocketManager) {
        self.inner = inner
        self.manager = manager
    }
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                        sendAck: sending @escaping () throws -> Void) {
        inner.chatConnection(chat, didReceiveIncomingMessage: envelope, serverDeliveryTimestamp: serverDeliveryTimestamp, sendAck: sendAck)
    }
    func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) { inner.chatConnectionDidReceiveQueueEmpty(chat) }
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveAlerts alerts: [String]) { inner.chatConnection(chat, didReceiveAlerts: alerts) }
    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {
        inner.connectionWasInterrupted(service, error: error)
        manager.connectionInterrupted(service)
    }
}

// `Net` only holds native handles (Tokio context + connection manager) that the
// Rust side synchronises internally; Signal-iOS shares one instance across tasks.
extension Net: @retroactive @unchecked Sendable {}

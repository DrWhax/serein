// How Serein's processes talk: XPC sessions (the XPC framework's XPCSession and XPCListener)
// carrying plain XPC dictionaries. No Objective-C proxies or NSSecureCoding: a message holds at
// most a payload in the wire format (Wire.swift), a listener endpoint and, in a reply, the
// reason a request failed. Nothing else in a dictionary is read, and a payload larger than the
// receiver expects is refused before it is copied out of the message. All of it in safe Swift:
// the payload travels as a base64 string (see XPCMessage).
//
// Peers are checked by the system (XPCPeer): a service's listener admits only sessions from a
// peer meeting its requirement, and the app's channels open sessions only to a peer meeting
// theirs, so a message from or to anything else is never delivered.

import Foundation
import Synchronization
import XPC

/// Where a channel connects: a bundled XPC service by name, or a listener's endpoint (handed
/// over by another service, or an in-process listener in tests).
public enum XPCTarget: Sendable {
    case service(String)
    case endpoint(XPCEndpoint)
}

/// One message between Serein's processes.
public struct XPCMessage: Sendable {
    /// A request or reply in the wire format.
    public var payload: Data?
    /// A listener endpoint (the parser's, from the parser service to the app to the fetcher).
    public var endpoint: XPCEndpoint?
    /// Why a request failed (replies only).
    public var error: String?

    public init(payload: Data? = nil, endpoint: XPCEndpoint? = nil, error: String? = nil) {
        self.payload = payload
        self.endpoint = endpoint
        self.error = error
    }

    /// The payload in base64, as an XPC string. Safe Swift cannot make an XPC data object: the
    /// C constructor takes a pointer, and XPCDictionary's RawSpan setter crashes the Swift 6.4
    /// compiler. A third larger; about 20 ms per 48 MiB each way.
    static let payloadKey = "w"
    static let endpointKey = "endpoint"
    /// An XPC string (UTF-8).
    static let errorKey = "e"
    /// The sender cuts longer errors; a receiver does not read one longer than this (they are
    /// only shown and logged).
    static let maxErrorBytes = 512
    static let unreadError = "(an error too long to read)"

    /// The entries this format knows, read from a received dictionary: a payload only if it is
    /// at most `maxPayload` bytes (the string's length is checked before it is copied; a string
    /// that is not base64 is refused like a payload too large), an error only if it is at most
    /// `maxErrorBytes`. An entry of the wrong XPC type counts as absent: each entry's type is
    /// checked first, since XPCDictionary's typed reads do not check it (its XPCEndpoint read
    /// wraps any object, and a string sent as "endpoint" would reach XPCSession(endpoint:)).
    init(_ dictionary: XPCDictionary, maxPayload: Int) throws {
        if let entry = Self.entry(dictionary, Self.payloadKey, "OS_xpc_string") {
            guard xpc_string_get_length(entry) <= Self.base64Length(maxPayload), let text = dictionary[Self.payloadKey, as: String.self],
                  let bytes = Data(base64Encoded: text), bytes.count <= maxPayload else { throw MediaProcessingError.invalidResult }
            payload = bytes
        }
        if Self.entry(dictionary, Self.endpointKey, "OS_xpc_endpoint") != nil {
            endpoint = dictionary[Self.endpointKey, as: XPCEndpoint.self]
        }
        if let entry = Self.entry(dictionary, Self.errorKey, "OS_xpc_string") {
            error = xpc_string_get_length(entry) <= Self.maxErrorBytes ? dictionary[Self.errorKey, as: String.self] ?? "" : Self.unreadError
        }
    }

    /// The dictionary sent.
    var dictionary: XPCDictionary {
        var d = XPCDictionary()
        if let payload { d[Self.payloadKey] = payload.base64EncodedString() }
        if let endpoint { d[Self.endpointKey] = endpoint }
        if let error { d[Self.errorKey] = Self.cut(error) }
        return d
    }

    /// The entry under `key` if its XPC type is the one of class `type`. XPC objects are
    /// Objective-C objects of class OS_xpc_<type> (the C type constants are pointers, out of
    /// reach of safe Swift); a class the runtime does not have matches nothing, so the entry
    /// counts as absent.
    static func entry(_ d: XPCDictionary, _ key: String, _ type: String) -> xpc_object_t? {
        guard let object = d[key, as: xpc_object_t.self], let cls = NSClassFromString(type), object.isKind(of: cls) else { return nil }
        return object
    }

    /// The longest base64 text of at most `bytes` bytes.
    static func base64Length(_ bytes: Int) -> Int { bytes > (Int.max / 4 - 1) * 3 ? Int.max : (bytes + 2) / 3 * 4 }

    /// `error` cut to at most `maxErrorBytes` of UTF-8, at a character boundary (an XPC string
    /// also ends at a NUL).
    static func cut(_ error: String) -> String {
        guard error.utf8.count > maxErrorBytes else { return error }
        var out = "", count = 0
        for c in error {
            count += c.utf8.count
            if count > maxErrorBytes { break }
            out.append(c)
        }
        return out
    }

    /// A reply's payload, or the error it carries.
    public func result() throws -> Data {
        if let payload { return payload }
        throw MediaProcessingError.undecodable(error ?? "no reply")
    }
}

// MARK: - Client

/// One service's session: reopened after it is cancelled (the service crashed or exited, or
/// refused this process), each request bounded by a watchdog. With a peer requirement
/// (XPCPeer) the session only talks to a process signed that way: anything else ends the
/// session before a reply is delivered.
///
/// A request is outstanding from its send until the first of: its reply, its failure (the
/// session broke), its timeout, its caller's cancellation. Only then does anything reach the
/// caller, and only once; the system hands a reply only to the request it answers (Verification/
/// Broker). A reply after the end is too late: it goes to the request's `late` handler, if any.
public final class XPCChannel: Sendable {
    let target: XPCTarget
    let peer: XPCPeerRequirement?
    let timeout: Duration
    struct Live {
        let session: XPCSession
        let id: UInt64
    }
    let state = Mutex<(live: Live?, next: UInt64)>((nil, 0))
    /// The watchdog's wait for the `n`th request (tests fire timeouts themselves).
    let sleep: @Sendable (_ n: UInt64, Duration) async -> Void
    let requests = Atomic<UInt64>(0)

    public convenience init(_ target: XPCTarget, peer: XPCPeerRequirement?, timeout: Duration) {
        self.init(target, peer: peer, timeout: timeout) { _, d in try? await Task.sleep(for: d) }
    }

    init(_ target: XPCTarget, peer: XPCPeerRequirement?, timeout: Duration, sleep: @escaping @Sendable (_ n: UInt64, Duration) async -> Void) {
        self.target = target
        self.peer = peer
        self.timeout = timeout
        self.sleep = sleep
    }

    deinit {
        // A session must be cancelled before it is released.
        state.withLock { $0.live?.session.cancel(reason: "channel closed") }
    }

    /// The open session, or a new one.
    func current() throws -> Live {
        if let live = state.withLock({ $0.live }) { return live }
        let id = state.withLock { st in
            defer { st.next += 1 }
            return st.next
        }
        let weakSelf = WeakBox(self)
        let cancelled: @Sendable (XPCRichError) -> Void = { _ in weakSelf.value?.drop(id) }
        // Made outside the lock: activation may cancel the session (and run that handler).
        let session: XPCSession
        switch target {
        case .service(let name): session = try XPCSession(xpcService: name, options: .inactive, cancellationHandler: cancelled)
        case .endpoint(let endpoint): session = try XPCSession(endpoint: endpoint, options: .inactive, cancellationHandler: cancelled)
        }
        if let peer { session.setPeerRequirement(peer) }
        try session.activate()   // a failed activation cancels the session
        let fresh = Live(session: session, id: id)
        let winner = state.withLock { st -> Live? in
            if let live = st.live { return live }
            st.live = fresh
            return nil
        }
        if let winner {
            session.cancel(reason: "another request opened the session")
            return winner
        }
        return fresh
    }

    /// Session `id` is done for (cancelled, or a reply on it failed): forgotten, so the next
    /// request opens a new one, and cancelled (again, harmlessly, if it already was: an active
    /// session must not be released uncancelled).
    func drop(_ id: UInt64) {
        let dropped = state.withLock { st -> XPCSession? in
            guard let live = st.live, live.id == id else { return nil }
            st.live = nil
            return live.session
        }
        dropped?.cancel(reason: "session failed")
    }

    /// One request: `message` sent, its reply (a payload of at most `maxReply` bytes) handed to
    /// `read`. `timeout` (at most the channel's) bounds the wait; a broken session fails with
    /// XPCServiceError.lost; the caller's cancellation ends it at once with CancellationError
    /// (nothing is sent if it came first). A reply after the request ended goes to `late`; a
    /// request ended by its session's loss tells `lost` which session that was (sessions are
    /// numbered by the channel) before its caller resumes.
    func request<T: Sendable>(_ message: XPCMessage, timeout: Duration? = nil, maxReply: Int, late: (@Sendable (XPCMessage) -> Void)? = nil,
                              lost: (@Sendable (UInt64) -> Void)? = nil,
                              _ read: @escaping @Sendable (XPCMessage) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let live: Live
        do { live = try current() } catch { throw XPCServiceError.lost(String(String(describing: error).prefix(512))) }
        let timeout = min(timeout ?? self.timeout, self.timeout)
        let dictionary = message.dictionary
        let n = requests.add(1, ordering: .relaxed).oldValue
        let outcome = Outcome<T>(), sleep = sleep
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
                guard outcome.wait(k) else { return }   // cancelled already: nothing sent
                outcome.watch(Task {
                    await sleep(n, timeout)
                    outcome.finish(.failure(XPCServiceError.timedOut))
                })
                let weakSelf = WeakBox(self)
                live.session.send(message: dictionary) { reply in
                    switch reply {
                    case .success(let d):
                        let received = Result { try XPCMessage(d, maxPayload: maxReply) }
                        if !outcome.finish(received.flatMap { m in Result { try read(m) } }), let late, case .success(let m) = received { late(m) }
                    case .failure(let e):
                        // Before the cancellation handler runs, so no later request is sent on it.
                        weakSelf.value?.drop(live.id)
                        outcome.finish(.failure(XPCServiceError.lost(String(String(describing: e).prefix(512))))) { lost?(live.id) }
                    }
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// Ends the open session, if any; the next request opens a new one. (A service that exits
    /// when its session ends, as the calling service does, drops everything it held.)
    public func reset() {
        let dropped = state.withLock { st -> XPCSession? in
            defer { st.live = nil }
            return st.live?.session
        }
        dropped?.cancel(reason: "reset by the app")
    }

    /// One request from a thread that may block (never this channel's own handlers): `payload`
    /// sent, the reply's payload (at most `maxReply` bytes) returned. A reply later than
    /// `timeout` ends the session, as the service is stuck: nothing waits on it again, and the
    /// next request opens a new one. (For callers whose API is synchronous: ringrtc's commands.)
    public func sendSync(_ payload: Data, timeout: Duration, maxReply: Int) throws -> Data {
        let live: Live
        do { live = try current() } catch { throw XPCServiceError.lost(String(String(describing: error).prefix(512))) }
        let reply = SyncReply()
        let weakSelf = WeakBox(self)
        live.session.send(message: XPCMessage(payload: payload).dictionary) { r in
            switch r {
            case .success(let d): reply.finish(Result { try XPCMessage(d, maxPayload: maxReply).result() })
            case .failure(let e):
                weakSelf.value?.drop(live.id)
                reply.finish(.failure(XPCServiceError.lost(String(String(describing: e).prefix(512)))))
            }
        }
        guard let result = reply.wait(timeout) else {
            drop(live.id)
            throw XPCServiceError.timedOut
        }
        return try result.get()
    }

    /// A payload sent, the reply's payload (at most `maxReply` bytes) returned undecoded.
    func send(_ payload: Data, timeout: Duration? = nil, maxReply: Int, late: (@Sendable (Data) -> Void)? = nil,
              lost: (@Sendable (UInt64) -> Void)? = nil) async throws -> Data {
        var lateMessage: (@Sendable (XPCMessage) -> Void)? = nil
        if let late { lateMessage = { m in if let p = m.payload { late(p) } } }
        return try await request(XPCMessage(payload: payload), timeout: timeout, maxReply: maxReply, late: lateMessage, lost: lost) { try $0.result() }
    }
}

/// A request's one ending: the first `finish` wins, and resumes the caller now or as soon as it
/// waits; the watchdog is stopped then.
final class Outcome<T: Sendable>: Sendable {
    struct State {
        var caller: CheckedContinuation<T, Error>?
        var result: Result<T, Error>?
        var watchdog: Task<Void, Never>?
    }
    let state = Mutex(State())

    /// True for the first call only, which runs `first` before the caller resumes.
    @discardableResult func finish(_ r: Result<T, Error>, first: (() -> Void)? = nil) -> Bool {
        let (won, caller, watchdog) = state.withLock { s -> (Bool, CheckedContinuation<T, Error>?, Task<Void, Never>?) in
            guard s.result == nil else { return (false, nil, nil) }
            s.result = r
            defer { s.caller = nil; s.watchdog = nil }
            return (true, s.caller, s.watchdog)
        }
        watchdog?.cancel()
        if won { first?() }
        caller?.resume(with: r)
        return won
    }

    /// The caller waits; false if the request already ended (it is resumed at once).
    func wait(_ k: CheckedContinuation<T, Error>) -> Bool {
        let ended = state.withLock { s -> Result<T, Error>? in
            if let r = s.result { return r }
            s.caller = k
            return nil
        }
        if let ended { k.resume(with: ended) }
        return ended == nil
    }

    func watch(_ t: Task<Void, Never>) {
        let ended = state.withLock { s -> Bool in
            if s.result != nil { return true }
            s.watchdog = t
            return false
        }
        if ended { t.cancel() }
    }
}

/// A blocking request's reply: the first result wins; the waiter gives up after its timeout.
final class SyncReply: Sendable {
    let result = Mutex<Result<Data, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)

    func finish(_ r: Result<Data, Error>) {
        let first = result.withLock { s -> Bool in
            guard s == nil else { return false }
            s = r
            return true
        }
        if first { done.signal() }
    }

    func wait(_ timeout: Duration) -> Result<Data, Error>? {
        let (seconds, attoseconds) = timeout.components
        let nanos = max(0, seconds) * 1_000_000_000 + attoseconds / 1_000_000_000
        guard done.wait(timeout: .now() + .nanoseconds(Int(clamping: nanos))) == .success else { return nil }
        return result.withLock { $0 }
    }
}

// MARK: - Service

/// A service's answer to each request on its sessions.
public protocol XPCMessageHandler: Sendable {
    /// The largest request payload read; a larger one is refused before it is copied.
    var maxRequestBytes: Int { get }
    /// The reply to one request. A thrown error goes back as the reply's reason.
    func reply(to request: XPCMessage) async throws -> XPCMessage
    /// A session ended (its peer went away, or cancelled it).
    func sessionEnded()
}

extension XPCMessageHandler {
    public func sessionEnded() {}
}

extension XPCMessage {
    /// A request's payload (every request but the parser service's carries one).
    public func requirePayload() throws -> Data {
        guard let payload else { throw MediaProcessingError.invalidResult }
        return payload
    }
}

/// A service whose one answer is the endpoint of its own anonymous listener for `handler`, open
/// to `requirement`'s peer alone: an empty message gets the endpoint, a message with a payload is
/// refused. The link-preview parser's face towards the app (HTML reaches it from the fetcher only).
public final class EndpointService: XPCMessageHandler {
    let listener: XPCListener

    public init(requirement: XPCPeerRequirement?, _ handler: some XPCMessageHandler) {
        listener = XPCServer.anonymous(requirement: requirement, handler)
    }

    deinit { listener.cancel() }

    public var maxRequestBytes: Int { 0 }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        guard request.payload == nil else { throw MediaProcessingError.unsupportedFormat }
        return XPCMessage(endpoint: listener.endpoint)
    }
}

public enum XPCServer {
    /// A bundled service's listener: only a peer meeting `requirement` gets a session (the
    /// system checks it before handing over a message). Serves forever; a listener that cannot
    /// be made ends the process.
    public static func serve(_ service: String, requirement: XPCPeerRequirement, _ handler: some XPCMessageHandler) -> Never {
        let listener: XPCListener
        do {
            listener = try XPCListener(service: service, requirement: requirement) { $0.accept { _ in Session(handler: handler) } }
        } catch {
            FileHandle.standardError.write(Data("\(service): cannot listen: \(error)\n".utf8))
            exit(78)
        }
        withExtendedLifetime(listener) { dispatchMain() }
    }

    /// An anonymous listener (its endpoint handed to the one peer that may use it, or tests),
    /// each session restricted to a peer meeting `requirement` when given.
    public static func anonymous(requirement: XPCPeerRequirement?, _ handler: some XPCMessageHandler) -> XPCListener {
        XPCListener { request in
            request.accept { session in
                if let requirement { session.setPeerRequirement(requirement) }
                return Session(handler: handler)
            }
        }
    }

    /// Each message handled in a task of its own and replied to when it finishes (the handlers
    /// bound how many run: RequestGate).
    struct Session<Handler: XPCMessageHandler>: XPCPeerHandler {
        let handler: Handler

        func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
            let received = Received(message: message), handler = handler
            Task {
                let reply: XPCMessage
                do { reply = try await handler.reply(to: try XPCMessage(received.message, maxPayload: handler.maxRequestBytes)) } catch {
                    reply = XPCMessage(error: String(describing: error))
                }
                received.message.reply(reply.dictionary)
            }
            return nil
        }

        func handleCancellation(error: XPCRichError) { handler.sessionEnded() }
    }

    /// A received message, replied to once by the task handling it (it is only read; the reply
    /// is a new dictionary).
    struct Received: @unchecked Sendable {
        let message: XPCDictionary
    }
}

// MARK: -

final class WeakBox<T: AnyObject>: Sendable where T: Sendable {
    weak let value: T?
    init(_ value: T) { self.value = value }
}

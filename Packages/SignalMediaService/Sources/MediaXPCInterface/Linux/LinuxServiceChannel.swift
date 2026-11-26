#if os(Linux)
import CLinuxServiceSocket
import Foundation
import LinuxServiceTransport
import Synchronization

/// One long-lived control socket owns the service session. Each request uses a
/// separate stream, so a slow call cannot consume another caller's reply.
public final class XPCChannel: Sendable {
    private struct Session: Sendable {
        let socket: Socket
        let generation: UInt64
        let requests = ActiveRequests()

        func end() {
            socket.interrupt()
            requests.end()
        }
    }

    private struct State {
        var session: Session?
        var generation: UInt64 = 0
    }

    private let target: XPCTarget
    private let peer: XPCPeerRequirement?
    private let timeout: Duration
    private let state = Mutex(State())

    public init(_ target: XPCTarget, peer: XPCPeerRequirement?, timeout: Duration) {
        self.target = target
        self.peer = peer
        self.timeout = timeout
    }

    deinit { reset() }

    private func begin() throws -> (Session, Socket) {
        let session = try state.withLock { state in
            if let session = state.session { return session }
            let socket = try target.open(peer: peer)
            let session = Session(socket: socket, generation: state.generation)
            state.generation &+= 1
            state.session = session
            return session
        }
        let socket: Socket
        do { socket = try Socket(serein_open_channel(session.socket.fd, 1, 0, 0)) }
        catch { drop(session.generation); throw error }
        guard session.requests.insert(socket) else { throw XPCServiceError.busy }
        return (session, socket)
    }

    private func drop(_ generation: UInt64?) {
        let ended = state.withLock { state -> Session? in
            guard let session = state.session, generation == nil || generation == session.generation else { return nil }
            state.session = nil
            return session
        }
        ended?.end()
    }

    public func reset() { drop(nil) }

    private func exchange(_ message: XPCMessage, on socket: Socket, maxReply: Int) throws -> XPCMessage {
        do {
            try message.write(to: socket)
            return try XPCMessage.read(from: socket, maxPayload: maxReply)
        } catch ServicePipeError.tooLarge { throw MediaProcessingError.invalidResult }
        catch let error as ServicePipeError { throw XPCServiceError.lost(String(describing: error)) }
    }

    func request<T: Sendable>(_ message: XPCMessage, timeout: Duration? = nil, maxReply: Int,
                              late: (@Sendable (XPCMessage) -> Void)? = nil,
                              lost: (@Sendable (UInt64) -> Void)? = nil,
                              _ read: @escaping @Sendable (XPCMessage) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let (session, socket) = try begin()
        let outcome = Outcome<T>()
        let deadline = min(timeout ?? self.timeout, self.timeout)
        // When late completion carries resource cleanup, allow it a bounded
        // window. Otherwise a timed-out or cancelled reader can stop at once.
        let stop: @Sendable () -> Void = {
            if late == nil { socket.interrupt() }
            else { DispatchQueue.global().asyncAfter(deadline: .now() + 5) { socket.interrupt() } }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (caller: CheckedContinuation<T, Error>) in
                guard outcome.wait(caller) else { session.requests.remove(socket); return }
                outcome.watch(Task {
                    do { try await Task.sleep(for: deadline) } catch { return }
                    outcome.finish(.failure(XPCServiceError.timedOut), first: stop)
                })
                DispatchQueue.global().async {
                    defer { session.requests.remove(socket) }
                    do {
                        let reply = try self.exchange(message, on: socket, maxReply: maxReply)
                        if !outcome.finish(Result { try read(reply) }) { late?(reply) }
                    } catch let error as XPCServiceError {
                        outcome.finish(.failure(error)) {
                            self.drop(session.generation)
                            lost?(session.generation)
                        }
                    } catch {
                        outcome.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()), first: stop)
        }
    }

    func send(_ payload: Data, timeout: Duration? = nil, maxReply: Int,
              late: (@Sendable (Data) -> Void)? = nil, lost: (@Sendable (UInt64) -> Void)? = nil) async throws -> Data {
        var lateMessage: (@Sendable (XPCMessage) -> Void)?
        if let late { lateMessage = { message in if let payload = message.payload { late(payload) } } }
        return try await request(.init(payload: payload), timeout: timeout, maxReply: maxReply,
                                 late: lateMessage, lost: lost) { try $0.result() }
    }

    public func sendSync(_ payload: Data, timeout: Duration, maxReply: Int) throws -> Data {
        let (session, socket) = try begin()
        let reply = SyncReply()
        DispatchQueue.global().async {
            defer { session.requests.remove(socket) }
            do {
                let received = try self.exchange(.init(payload: payload), on: socket, maxReply: maxReply)
                reply.finish(Result { try received.result() })
            } catch let error as XPCServiceError {
                self.drop(session.generation)
                reply.finish(.failure(error))
            } catch {
                reply.finish(.failure(error))
            }
        }
        guard let result = reply.wait(timeout) else {
            drop(session.generation)
            throw XPCServiceError.timedOut
        }
        return try result.get()
    }
}
#endif

import Foundation
import SignalRingRTC
import Synchronization

/// A join or roster poll is associated with the room task that issued it. Reserve
/// the high bit so the app's replies cannot collide with standalone call-link CRUD.
final class GroupHTTP: Sendable {
    typealias Reply = (status: Int, body: Data)
    private struct State {
        var next: UInt32 = 0
        var closed = false
        var requests: [UInt32: AsyncStream<Reply>.Continuation] = [:]
    }
    private let state = Mutex(State())

    func perform(_ request: JSONValue, emit: @Sendable (JSONValue) -> Void) async -> Reply {
        guard case .object(var fields) = request, !Task.isCancelled else { return (602, Data()) }
        let (stream, continuation) = AsyncStream<Reply>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { s -> UInt32? in
            guard !s.closed, s.requests.count < 64 else { return nil }
            repeat { s.next = (s.next &+ 1) | 0x8000_0000 } while s.requests[s.next] != nil
            s.requests[s.next] = continuation
            return s.next
        }
        guard let id else { return (602, Data()) }
        defer { state.withLock { $0.requests.removeValue(forKey: id) }?.finish() }
        fields["requestId"] = .int(Int64(id))
        emit(.object(fields))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            continuation.finish()
        }
        defer { timeout.cancel() }
        for await reply in stream { return reply }
        return (602, Data())
    }

    func complete(_ name: String, _ fields: [String: JSONValue]) -> Bool {
        guard let id = fields["requestId"]?.uint64.flatMap(UInt32.init(exactly:)), id >= 0x8000_0000 else { return false }
        let continuation = state.withLock { $0.requests.removeValue(forKey: id) }
        let body = fields["body"]?.data
        if name == "receivedHttpResponse", let status = fields["statusCode"]?.int, let body, body.count <= 1 << 20 {
            continuation?.yield((status, body))
        }
        continuation?.finish()
        return true
    }

    func close() {
        state.withLock { s in
            s.closed = true
            for request in s.requests.values { request.finish() }
            s.requests.removeAll()
        }
    }
}

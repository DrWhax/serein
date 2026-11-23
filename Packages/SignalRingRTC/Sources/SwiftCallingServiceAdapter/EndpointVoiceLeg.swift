import Foundation
import SwiftCalling

/// One ordered stream of signaling and app commands for one media actor. An endpoint may
/// receive several XPC commands before its first asynchronous operation reaches that actor.
final class EndpointVoiceLeg: Sendable {
    typealias Work = @Sendable (LiveVoiceSession) async throws -> Void

    let id: UUID
    let session: LiveVoiceSession
    private let commands: AsyncStream<Work>.Continuation
    private let worker: Task<Void, Never>
    init(id: UUID, session: LiveVoiceSession, failed: @escaping @Sendable () -> Void) {
        self.id = id
        self.session = session
        let (stream, commands) = AsyncStream<Work>.makeStream(bufferingPolicy: .bufferingOldest(128))
        self.commands = commands
        worker = Task {
            do {
                for await work in stream {
                    try Task.checkCancellation()
                    try await work(session)
                }
            } catch {
                if !Task.isCancelled { failed() }
            }
        }
    }

    func enqueue(_ work: @escaping Work) -> Bool {
        if case .enqueued = commands.yield(work) { return true }
        return false
    }

    func end(sendHangup: Bool) {
        session.revokeCapture()
        worker.cancel()
        commands.finish()
        // End goes straight to the media actor, including while it is awaiting permission
        // or network I/O. Each leg has its own device objects and network resources.
        Task { await session.end(sendHangup: sendHangup) }
    }
}

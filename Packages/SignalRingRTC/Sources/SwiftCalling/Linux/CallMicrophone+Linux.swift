#if os(Linux)
import CLinuxCallAudio
import Foundation

actor CallMicrophone {
    enum Failure: Error { case busy, permissionDenied, unavailable, closed }
    private var uid: String?
    private let echo: CallEchoControl?
    private let started: (@Sendable (Bool, String?) -> Void)?
    private var handle: UInt64 = 0
    private var token: UUID?
    private var reader: Task<Void, Never>?
    private var packets: AsyncStream<[Int16]>.Continuation?
    private var buffer = [Int16](repeating: 0, count: 960)

    init(uid: String? = nil, echo: CallEchoControl? = nil, started: (@Sendable (Bool, String?) -> Void)? = nil) {
        self.uid = uid
        self.echo = echo
        self.started = started
    }

    func start() async throws -> AsyncStream<[Int16]> {
        let stream = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(6))
        do { try open(stream.continuation) } catch {
            started?(false, uid)
            throw error
        }
        started?(true, uid)
        return stream.stream
    }
    func warmUp() async throws { try open(nil) }

    private func open(_ sink: AsyncStream<[Int16]>.Continuation?) throws {
        guard token == nil else { throw Failure.busy }
        handle = serein_call_pcm_open(Array((uid ?? "").utf8).span, 1)
        if handle == 0, uid != nil {
            uid = nil
            handle = serein_call_pcm_open([UInt8]().span, 1)
        }
        guard handle != 0 else { throw Failure.unavailable }
        let generation = UUID()
        token = generation
        packets = sink
        sink?.onTermination = { [weak self] _ in Task { await self?.end(generation) } }
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.read(generation) else { return }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func read(_ generation: UUID) -> Duration? {
        guard token == generation else { return nil }
        var destination = buffer.mutableSpan
        let result = serein_call_pcm_read(handle, &destination)
        if result.status < 0 { stop(); return nil }
        if result.status == 0 { return .milliseconds(4) }
        if let packets { packets.yield(echo?.capture(buffer, at: result.first_frame) ?? buffer) }
        return .milliseconds(15)
    }

    func select(_ next: String?) async throws {
        guard next != uid else { return }
        if token != nil {
            let previous = uid
            serein_call_pcm_close(handle)
            handle = serein_call_pcm_open(Array((next ?? "").utf8).span, 1)
            if handle == 0 {
                handle = serein_call_pcm_open(Array((previous ?? "").utf8).span, 1)
                if handle == 0 { stop() }
                throw Failure.unavailable
            }
            echo?.reset()
        }
        uid = next
    }

    private func end(_ generation: UUID) { if token == generation { stop() } }
    func stop() {
        token = nil
        reader?.cancel()
        reader = nil
        packets?.finish()
        packets = nil
        serein_call_pcm_close(handle)
        handle = 0
        echo?.reset()
    }
    isolated deinit {
        reader?.cancel()
        packets?.finish()
        serein_call_pcm_close(handle)
    }
}
#endif

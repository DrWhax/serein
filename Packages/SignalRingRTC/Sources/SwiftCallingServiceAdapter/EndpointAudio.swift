import Foundation
import SignalRingRTC
import SwiftCalling
import Synchronization

private extension VoiceAudioRoute {
    var json: JSONValue { .object(["name": .string(name), "uniqueId": .string(uid)]) }
}
private extension VoiceAudioRoutes {
    var json: JSONValue {
        .object(["devices": .array(devices.map(\.json)), "defaults": .object(["isWindows": .bool(false), "device": currentDefault?.json ?? .null])])
    }
}

final class EndpointAudio: Sendable {
    private enum Request: Sendable {
        case select(input: Bool, uid: String, id: UInt32)
        case processing(Bool, UInt32)
        case warm(Bool, UInt32)
        case changed
    }
    private struct State: Sendable {
        var emit: (@Sendable (JSONValue) -> Void)?
        var worker: Task<Void, Never>?
        var monitor: VoiceAudioMonitor?
        var inputs: VoiceAudioRoutes?
        var outputs: VoiceAudioRoutes?
    }
    private let state = Mutex(State())
    private let hardware = VoiceAudioHardware()
    private let requests = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingOldest(256))

    func devices() -> VoiceCallDevices {
        hardware.devices { [weak self] input, success, uid in
            guard let emit = self?.state.withLock({ $0.emit }) else { return }
            let routes = try? VoiceAudioRoutes.read(input: input)
            let device = uid.flatMap { target in routes?.devices.first { $0.uid == target } } ?? routes?.currentDefault
            emit(.object(["type": .string(input ? "onSettleStartRecording" : "onSettleStartPlayback"),
                          "success": .bool(success), "device": device?.json ?? .null]))
        }
    }

    func start(emit: @escaping @Sendable (JSONValue) -> Void) {
        state.withLock { s in
            s.emit = emit
            s.worker = Task.detached { [weak self, requests, hardware] in
                for await request in requests.stream {
                    guard !Task.isCancelled else { break }
                    if case .changed = request {
                        await self?.refresh(emit)
                        continue
                    }
                    let (id, success, device) = await Self.perform(request, hardware)
                    if id != 0, !Task.isCancelled {
                        emit(.object(["type": .string("onSettleAudioPromise"), "requestId": .int(Int64(id)),
                                      "success": .bool(success), "device": device?.json ?? .null]))
                    }
                }
                try? await hardware.warm(false)
            }
        }
    }

    private func observe() throws {
        try state.withLock { s in
            if s.monitor == nil {
                s.monitor = try VoiceAudioMonitor { [requests] in requests.continuation.yield(.changed) }
            }
        }
    }

    func list(input: Bool) throws -> JSONValue {
        // Install before reading the snapshot so a concurrent hotplug cannot go undetected.
        try observe()
        let result = try VoiceAudioRoutes.read(input: input)
        state.withLock { s in
            if input, s.inputs == nil { s.inputs = result }
            if !input, s.outputs == nil { s.outputs = result }
        }
        return result.json
    }

    private func refresh(_ emit: @Sendable (JSONValue) -> Void) async {
        for input in [true, false] {
            guard let current = try? VoiceAudioRoutes.read(input: input) else { continue }
            let changed = state.withLock { s in
                let previous = input ? s.inputs : s.outputs
                if input { s.inputs = current } else { s.outputs = current }
                return previous != current
            }
            guard changed else { continue }
            await hardware.refresh(input: input, routes: current)
            emit(.object(["type": .string(input ? "onInputDeviceChanged" : "onOutputDeviceChanged"), "devices": current.json]))
        }
    }

    func submit(_ command: String, fields: [String: JSONValue]) throws {
        guard let value = fields["requestId"]?.uint64, let id = UInt32(exactly: value) else { throw RingRTCError.invalidResponse }
        let request: Request
        switch command {
        case "setAudioInputById", "setAudioOutputById":
            guard let uid = fields["id"]?.string, (1...4096).contains(uid.utf8.count) else { throw RingRTCError.invalidResponse }
            try observe()
            let preferred = fields["followSystemDefault"]?.bool == true ? "default" : uid
            request = .select(input: command == "setAudioInputById", uid: preferred, id: id)
        default:
            guard let enabled = fields["enabled"]?.bool else { throw RingRTCError.invalidResponse }
            request = command == "setVoiceProcessingEnabled" ? .processing(enabled, id) : .warm(enabled, id)
        }
        guard case .enqueued = requests.continuation.yield(request) else { throw RingRTCError.native("Audio command queue unavailable") }
    }

    private static func perform(_ request: Request, _ hardware: VoiceAudioHardware) async -> (UInt32, Bool, VoiceAudioRoute?) {
        switch request {
        case let .select(input, uid, id):
            let routes = try? VoiceAudioRoutes.read(input: input)
            let device = uid == "default" ? routes?.currentDefault : routes?.devices.first { $0.uid == uid }
            guard let device else { return (id, false, nil) }
            do {
                try await hardware.select(input: input, uid: uid == "default" ? nil : device.uid)
                return (id, true, device)
            } catch { return (id, false, device) }
        case let .processing(enabled, id):
            hardware.setProcessing(enabled)
            return (id, true, nil)
        case let .warm(enabled, id):
            do { try await hardware.warm(enabled); return (id, true, nil) }
            catch { return (id, false, nil) }
        case .changed: return (0, false, nil)
        }
    }

    func close() {
        requests.continuation.finish()
        state.withLock { s in
            s.worker?.cancel()
            s.worker = nil
            s.emit = nil
            s.monitor = nil
        }
        // Also invalidate a pending microphone permission request immediately.
        Task { [hardware] in try? await hardware.warm(false) }
    }
}

import CoreAudio
import Foundation
import Synchronization

package struct VoiceAudioRoute: Sendable, Equatable {
    package let uid: String
    package let name: String
}

package struct VoiceAudioRoutes: Sendable, Equatable {
    package let devices: [VoiceAudioRoute]
    package let currentDefault: VoiceAudioRoute?

    package static func read(input: Bool) throws -> Self {
        let system = AudioHardwareSystem.shared
        let preferred = try (input ? system.defaultInputDevice : system.defaultOutputDevice)?.uid
        let devices = try system.devices.compactMap { device -> VoiceAudioRoute? in
            guard (try? device.isAlive) == true, (try? device.isHidden) == false,
                  let streams = try? device.streams,
                  streams.contains(where: { (try? $0.direction) == (input ? .input : .output) }),
                  let uid = try? device.uid, let name = try? device.name, !uid.isEmpty else { return nil }
            return VoiceAudioRoute(uid: uid, name: name)
        }
        return Self(devices: devices, currentDefault: devices.first { $0.uid == preferred })
    }
}

/// Each call leg owns its capture and playout. Preferences outlive a leg, including settings
/// applied before the first call. Weak references prevent a late stop reaching the next call.
package final class VoiceAudioHardware: Sendable {
    private struct Pair: Sendable {
        weak var mic: CallMicrophone?
        weak var speaker: CallSpeaker?
        weak var echo: CallEchoControl?
    }
    private struct State: Sendable {
        var input: String?
        var output: String?
        var activeInput: String?
        var activeOutput: String?
        var processing = true
        var pairs: [Pair] = []
    }
    private let state = Mutex(State())
    private let warmer = CallMicrophone()
    package init() {}

    package func devices(started: @escaping @Sendable (_ input: Bool, _ success: Bool, _ uid: String?) -> Void) -> VoiceCallDevices {
        state.withLock { s in
            let echo = CallEchoControl(enabled: s.processing)
            let mic = CallMicrophone(uid: s.activeInput, echo: echo) { started(true, $0, $1) }
            let speaker = CallSpeaker(uid: s.activeOutput, echo: echo) { started(false, $0, $1) }
            s.pairs.removeAll { $0.mic == nil && $0.speaker == nil }
            s.pairs.append(Pair(mic: mic, speaker: speaker, echo: echo))
            return VoiceCallDevices(microphone: mic, speaker: speaker)
        }
    }

    /// Callers serialize changes. Publish the new selection before awaiting a running device
    /// so a leg created during the change consistently starts with the same preferences.
    package func select(input: Bool, uid: String?) async throws {
        let old = state.withLock { s -> (preferred: String?, active: String?) in
            if input {
                let old = (s.input, s.activeInput)
                s.input = uid
                s.activeInput = uid
                return old
            }
            let old = (s.output, s.activeOutput)
            s.output = uid
            s.activeOutput = uid
            return old
        }
        do {
            try await apply(input: input, uid: uid)
        } catch {
            state.withLock {
                if input { ($0.input, $0.activeInput) = old } else { ($0.output, $0.activeOutput) = old }
            }
            try? await apply(input: input, uid: old.active)
            throw error
        }
    }

    package func refresh(input: Bool, routes: VoiceAudioRoutes) async {
        let preferred = state.withLock { input ? $0.input : $0.output }
        let available = routes.devices.first { $0.uid == preferred }
        // A disconnected preferred device falls back to the system route until it returns.
        let next = available?.uid ?? routes.currentDefault?.uid
        state.withLock { if input { $0.activeInput = next } else { $0.activeOutput = next } }
        try? await apply(input: input, uid: next)
    }

    private func apply(input: Bool, uid: String?) async throws {
        let pairs = state.withLock { $0.pairs }
        if input {
            try await warmer.select(uid)
            for pair in pairs { try await pair.mic?.select(uid) }
        } else {
            for pair in pairs { try await pair.speaker?.select(uid) }
        }
    }

    package func setProcessing(_ enabled: Bool) {
        state.withLock { s in
            s.processing = enabled
            for pair in s.pairs { pair.echo?.setEnabled(enabled) }
        }
    }

    package func warm(_ enabled: Bool) async throws {
        if enabled {
            do { try await warmer.warmUp() } catch CallMicrophone.Failure.busy { return }
        } else {
            await warmer.stop()
        }
    }
}

package final class VoiceAudioMonitor: Sendable {
    private final class Listener: PropertyListenerDelegate, Sendable {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
        func propertiesChanged(properties: [AudioObjectPropertyAddress]) { changed() }
    }
    private let system = AudioHardwareObject(id: AudioObjectID(kAudioObjectSystemObject))
    private let queue = DispatchQueue(label: "org.serein.call.audioDevices")
    private let properties = [PropertyAddress(kAudioHardwarePropertyDevices),
                              PropertyAddress(kAudioHardwarePropertyDefaultInputDevice),
                              PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)]

    package init(changed: @escaping @Sendable () -> Void) throws {
        system.delegates = [Listener(changed)]
        try system.addListener(forProperties: properties, dispatchQueue: queue)
    }

    deinit { try? system.removeListener(forProperties: properties, dispatchQueue: queue) }
}

// @signalapp/mute-state-change (macOS 14+): the system's microphone mute (the menu-bar mic
// indicator and AirPods' stem press) kept in step with the call's mute — set when the user
// mutes in the app, and reported when they mute from the system.

import AVFAudio

@MainActor
public final class MuteState {
    public static let shared = MuteState()
    var subscribers: [UInt64: (Bool) -> Void] = [:]
    var nextId: UInt64 = 0
    var installed = false

    public var isMuted: Bool { AVAudioApplication.shared.isInputMuted }

    /// `setIsMuted`
    public func setIsMuted(_ muted: Bool) {
        install()
        try? AVAudioApplication.shared.setInputMuted(muted)
    }

    /// `subscribe`: `body` hears every system mute change; the returned token unsubscribes.
    @discardableResult
    public func subscribe(_ body: @escaping (Bool) -> Void) -> UInt64 {
        install()
        nextId += 1
        subscribers[nextId] = body
        return nextId
    }

    public func unsubscribe(_ token: UInt64) { subscribers[token] = nil }

    func install() {
        guard !installed else { return }
        installed = true
        try? AVAudioApplication.shared.setInputMuteStateChangeHandler { muted in
            Task { @MainActor in MuteState.shared.changed(muted) }
            return true
        }
    }

    func changed(_ muted: Bool) {
        for s in subscribers.values { s(muted) }
    }
}

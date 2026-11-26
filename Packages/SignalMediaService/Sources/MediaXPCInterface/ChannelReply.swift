import Foundation
import Synchronization

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

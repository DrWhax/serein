import Foundation

/// Deterministic suspension with a bounded wait for the operation reaching the gate.
actor AsyncTestGate {
    private var entered = false
    private var open = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !entered {
            guard ContinuousClock.now < deadline else { throw HarnessError(description: "operation did not reach gate") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() {
        open = true
        for c in continuations { c.resume() }
        continuations = []
    }
}

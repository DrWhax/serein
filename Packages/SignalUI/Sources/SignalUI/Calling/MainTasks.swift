// Starts the main-actor tasks of the call and capture lifecycle (the session's tasks, the
// camera reconciler's pass, the hops of frame and stop callbacks). `system` is `Task { }`.
// The conformance tests (SignalSafeTests/CallCaptureConformanceTests) pass one that holds each
// task until their trace runs it, so any order of tasks, device completions and user actions
// can be replayed exactly, without relying on how the main actor orders its queue.

public struct MainTasks: Sendable {
    /// Starts `work` on the main actor; `label` names the spawn site.
    public var spawn: @Sendable (_ label: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>

    public init(spawn: @escaping @Sendable (_ label: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>) {
        self.spawn = spawn
    }

    public static let system = MainTasks { _, work in Task { @MainActor in await work() } }
}

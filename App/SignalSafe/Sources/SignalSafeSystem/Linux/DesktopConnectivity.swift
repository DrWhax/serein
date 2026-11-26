#if os(Linux)
import CLinuxDesktop

@MainActor public final class ConnectivityMonitor {
    private var watch: Task<Void, Never>?

    public init(onChange: @escaping @MainActor () -> Void) {
        watch = Task {
            var previous = serein_network_signature()
            var suspended = serein_suspended_milliseconds()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let current = serein_network_signature()
                let rest = serein_suspended_milliseconds()
                if current != 0 && (current != previous || rest - suspended > 250) { onChange() }
                previous = current
                suspended = rest
            }
        }
    }

    public func stop() { watch?.cancel(); watch = nil }
    deinit { watch?.cancel() }
}
#endif

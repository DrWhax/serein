// Reconnects at once when the Mac wakes or the network changes (upstream reconnects on its
// 'online' event and after sleep): the chat connections may have died unnoticed, and a socket
// waiting out its reconnect backoff would otherwise come back up to 30 s later.

import AppKit
import Network

@MainActor final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    private let onChange: @MainActor () -> Void
    /// The usable interfaces last seen ("offline" without a path).
    private var lastPath: String?
    private var pending: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let key = path.status == .satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "offline"
            Task { @MainActor in self?.pathChanged(key) }
        }
        monitor.start(queue: DispatchQueue(label: "org.signalsafe.connectivity"))
    }

    /// A different set of usable interfaces (back online, another network); the first report is
    /// the current state, and going offline leaves nothing to reconnect to.
    private func pathChanged(_ key: String) {
        defer { lastPath = key }
        guard let last = lastPath, last != key, key != "offline" else { return }
        changed()
    }

    /// One reconnect for a burst of changes (a wake brings the interfaces back one by one).
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    func stop() {
        monitor.cancel()
        pending?.cancel()
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
    }
}

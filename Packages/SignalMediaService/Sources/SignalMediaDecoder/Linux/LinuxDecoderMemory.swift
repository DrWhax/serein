#if os(Linux)
import Foundation

enum LinuxDecoderMemory {
    /// In Docker's cgroup namespace the process group is the mount root.
    /// On a desktop the unified hierarchy also includes the process group path.
    private static let directory: URL = {
        let root = URL(fileURLWithPath: "/sys/fs/cgroup", isDirectory: true)
        guard let groups = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8),
              let path = groups.split(separator: "\n").first(where: { $0.hasPrefix("0::/") }) else { return root }
        return root.appendingPathComponent(String(path.dropFirst(4)), isDirectory: true)
    }()

    static var availableBytes: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        let file = directory.appendingPathComponent("memory.max")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let limit = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return physical }
        return min(physical, limit)
    }

    struct Events {
        let high: UInt64
        let max: UInt64
        let oom: UInt64

        init?(_ text: String) {
            var counters: [Substring: UInt64] = [:]
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: " ")
                if fields.count == 2 { counters[fields[0]] = UInt64(fields[1]) }
            }
            guard let high = counters["high"], let max = counters["max"], let oom = counters["oom"] else { return nil }
            self.high = high
            self.max = max
            self.oom = oom
        }

        static func current() -> Self? {
            guard let text = try? String(contentsOf: directory.appendingPathComponent("memory.events"), encoding: .utf8)
            else { return nil }
            return Self(text)
        }
    }
}

extension MediaDecoder {
    static let memoryPressure = Task(priority: .utility) {
        var previous = LinuxDecoderMemory.Events.current()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let current = LinuxDecoderMemory.Events.current() else { continue }
            if let previous {
                let critical = current.max > previous.max || current.oom > previous.oom
                if critical || current.high > previous.high { await videoSessions.shed(critical: critical) }
            }
            previous = current
        }
    }
}
#endif

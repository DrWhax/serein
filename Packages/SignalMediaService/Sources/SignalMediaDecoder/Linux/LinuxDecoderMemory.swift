#if os(Linux)
import Foundation
import Synchronization

enum LinuxDecoderMemory {
    /// In Docker's cgroup namespace the process group is the mount root.
    /// On a desktop the unified hierarchy also includes the process group path.
    private static let directory: URL = {
        let root = URL(fileURLWithPath: "/sys/fs/cgroup", isDirectory: true)
        guard let groups = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8),
              let path = groups.split(separator: "\n").first(where: { $0.hasPrefix("0::/") }) else { return root }
        return root.appendingPathComponent(String(path.dropFirst(4)), isDirectory: true)
    }()

    // Only these two read-only kernel counters survive entry into the decoder's
    // fileless sandbox. Serialize seek/read so samples always start at offset 0.
    private static let limitFile = counter("memory.max"), eventsFile = counter("memory.events")
    private static func counter(_ name: String) -> Mutex<FileHandle?> {
        Mutex(try? FileHandle(forReadingFrom: directory.appendingPathComponent(name)))
    }
    private static func read(_ file: borrowing Mutex<FileHandle?>) -> String? {
        file.withLock { handle in
            guard let handle else { return nil }
            do {
                try handle.seek(toOffset: 0)
                let bytes = try handle.read(upToCount: 4096) ?? Data()
                return String(decoding: bytes, as: UTF8.self)
            } catch { return nil }
        }
    }

    static func prepare() {
        _ = read(limitFile)
        _ = read(eventsFile)
    }
    static var availableBytes: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        guard let text = read(limitFile),
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
            guard let text = read(eventsFile) else { return nil }
            return Self(text)
        }
    }
}

extension MediaDecoder {
    public static func prepareLinuxMemoryCounters() { LinuxDecoderMemory.prepare() }
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

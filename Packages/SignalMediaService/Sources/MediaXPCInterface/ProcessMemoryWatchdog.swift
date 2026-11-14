// Process-wide backstop for decoder scratch, reference pictures and retained replies.
// This sampled limit is not an allocation quota: transient overshoot is possible.
import Darwin
import Foundation

public final class ProcessMemoryWatchdog: Sendable {
    public static let defaultLimit: UInt64 = 2 * 1024 * 1024 * 1024
    let limit: UInt64
    let measure: @Sendable () -> UInt64?
    let terminate: @Sendable () -> Void

    public init(limit: UInt64 = ProcessMemoryWatchdog.defaultLimit,
                measure: @escaping @Sendable () -> UInt64? = ProcessMemoryWatchdog.footprint,
                terminate: @escaping @Sendable () -> Void = { _exit(70) }) {
        precondition(limit > 0)
        self.limit = limit
        self.measure = measure
        self.terminate = terminate
    }

    /// Failed measurement fails closed; otherwise an unavailable metric silently disables
    /// the backstop. Check even while idle, since caches and replies can retain memory.
    public func check() {
        guard let bytes = measure(), bytes <= limit else { terminate(); return }
    }

    public func start() {
        check()
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                check()
            }
        }
    }

    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        // The rebound view covers exactly this initialized stack struct. The kernel
        // receives its capacity in integer_t words; no media-derived pointer or length.
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            unsafe ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

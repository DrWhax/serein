import MediaXPCInterface
import Synchronization
import Testing

struct ProcessMemoryWatchdogTests {
    @Test func footprintIsAvailable() {
        #expect((ProcessMemoryWatchdog.footprint() ?? 0) > 0)
    }

    @Test func enforcesLimitIncludingWhenIdle() {
        let bytes = Mutex<UInt64?>(100)
        let exits = Atomic<Int>(0)
        let watchdog = ProcessMemoryWatchdog(limit: 100,
            measure: { bytes.withLock { $0 } },
            terminate: { exits.add(1, ordering: .relaxed) })
        watchdog.check()
        #expect(exits.load(ordering: .relaxed) == 0)
        bytes.withLock { $0 = 101 }
        watchdog.check()
        #expect(exits.load(ordering: .relaxed) == 1)
        bytes.withLock { $0 = nil }
        watchdog.check()
        #expect(exits.load(ordering: .relaxed) == 2)
    }
}

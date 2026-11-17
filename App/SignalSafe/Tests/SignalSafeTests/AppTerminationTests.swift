import AppKit
import Testing
@testable import SignalSafe

struct AppTerminationTests {
    /// Delete-and-relaunch asks AppKit to terminate from a main-actor task. The delegate
    /// must let that task return so its asynchronous shutdown can run and finish quitting.
    @Test func terminationFromMainActorTaskExits() async {
        await #expect(processExitsWith: .exitCode(0)) {
            // A watchdog on another queue also catches a blocked main actor.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(99) }
            let delegate = await MainActor.run { AppDelegate() }
            await MainActor.run {
                let app = NSApplication.shared
                app.delegate = delegate
                app.terminate(nil)
            }
            try await Task.sleep(for: .seconds(20))
            withExtendedLifetime(delegate) { exit(98) }
        }
    }
}

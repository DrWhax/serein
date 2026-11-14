import Foundation

ServiceSandbox.requireConfinement("memory-probe")
guard let initial = ProcessMemoryWatchdog.footprint() else { exit(2) }
ProcessMemoryWatchdog(limit: initial + 32 * 1024 * 1024).start()

struct Probe: XPCMessageHandler {
    var maxRequestBytes: Int { 1 }
    func reply(to request: XPCMessage) async throws -> XPCMessage {
        if request.payload == Data([1]) {
            // Touch pages and retain them until the dedicated watchdog ends this process.
            let bytes = [UInt8](repeating: 42, count: 128 * 1024 * 1024)
            withExtendedLifetime(bytes) { Thread.sleep(forTimeInterval: 5) }
            return XPCMessage(payload: Data("survived".utf8))
        }
        return XPCMessage(payload: Data("ready".utf8))
    }
}
XPCServer.serve(Bundle.main.bundleIdentifier!, requirement:
    XPCPeer.requirement(identifier: "org.signalsafe.SignalSafe", sameTeam: false), Probe())

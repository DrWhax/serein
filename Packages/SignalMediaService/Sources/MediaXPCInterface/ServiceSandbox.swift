// The services' start-up check that their Seatbelt profile is in force (Sandbox/*.sb, put in
// each service's entitlements by Tools/build-app.sh). An SBPL rule that does not compile is
// dropped silently, so the profile is tested, not assumed: no system file can be read and
// nothing can be written, not even in the service's own container. Fails closed.

import Foundation

public enum ServiceSandbox {
    public static func isConfined() -> Bool {
        let fm = FileManager.default
        if fm.contents(atPath: "/System/Library/CoreServices/SystemVersion.plist") != nil { return false }
        if fm.contents(atPath: "/etc/hosts") != nil { return false }
        let probe = NSTemporaryDirectory() + "sandbox-check"
        if fm.createFile(atPath: probe, contents: Data([0])) {
            try? fm.removeItem(atPath: probe)
            return false
        }
        return true
    }

    /// Exits (before serving anything) unless confined.
    public static func requireConfinement(_ service: String) {
        guard isConfined() else {
            FileHandle.standardError.write(Data("\(service): sandbox profile not in force, exiting\n".utf8))
            exit(78)
        }
    }
}

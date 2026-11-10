// The services' start-up check that their Seatbelt profile is in force (Sandbox/*.sb, put in
// each service's entitlements by Tools/build-app.sh). An SBPL rule that does not compile is
// dropped silently, so the profile is tested, not assumed: nothing can be written, not even
// in the service's own container, no program can be started, and (offline services) no system
// file can be read, or (the web-facing services, which need the system's TLS and DNS) nothing
// under the user's home. Fails closed.

import Foundation

public enum ServiceSandbox {
    /// The user's real home. Inside App Sandbox, NSHomeDirectory() and even
    /// homeDirectory(forUser:) name the container (~/Library/Containers/<id>/Data).
    public static var realHome: String {
        let home = NSHomeDirectory()
        if let r = home.range(of: "/Library/Containers/") { return String(home[..<r.lowerBound]) }
        return home
    }
    public static func isConfined(network: Bool = false) -> Bool {
        let fm = FileManager.default
        if !network {
            if fm.contents(atPath: "/System/Library/CoreServices/SystemVersion.plist") != nil { return false }
            if fm.contents(atPath: "/etc/hosts") != nil { return false }
        }
        if (try? fm.contentsOfDirectory(atPath: realHome)) != nil { return false }
        if (try? fm.contentsOfDirectory(atPath: "/Users")) != nil { return false }
        let probe = NSTemporaryDirectory() + "sandbox-check"
        if fm.createFile(atPath: probe, contents: Data([0])) {
            try? fm.removeItem(atPath: probe)
            return false
        }
        if (try? Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])) != nil { return false }
        return true
    }

    /// Exits (before serving anything) unless confined.
    public static func requireConfinement(_ service: String, network: Bool = false) {
        guard isConfined(network: network) else {
            FileHandle.standardError.write(Data("\(service): sandbox profile not in force, exiting\n".utf8))
            exit(78)
        }
    }
}

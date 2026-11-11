// The app's start-up check that App Sandbox and its Seatbelt rules (Packages/SignalMediaService/
// Sandbox/Serein.sb, put in its entitlements by Tools/build-app.sh) are in force. A rule that
// does not compile is dropped silently, so this is tested, not assumed: the process must be in
// a sandbox container, must not be able to start a program, and must not see the user's real
// home. It must also carry the signing identifiers of the XPC services it talks to
// (`SereinXPCPeers`, MediaXPCInterface/XPCPeer.swift): without them its clients would connect
// to the services unchecked. Applies to the bundled app only (`swift run` and tests are not
// sandboxed).

import AppKit
import Foundation

public enum AppSandbox {
    /// The user's real home. Inside App Sandbox, NSHomeDirectory() and even
    /// homeDirectory(forUser:) name the container (~/Library/Containers/<id>/Data).
    public static var realHome: String {
        let home = NSHomeDirectory()
        if let r = home.range(of: "/Library/Containers/") { return String(home[..<r.lowerBound]) }
        return home
    }
    public static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static func isConfined() -> Bool {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil else { return false }
        if (try? Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])) != nil { return false }
        let fm = FileManager.default
        if (try? fm.contentsOfDirectory(atPath: realHome + "/Documents")) != nil { return false }
        return true
    }

    /// The services' identifiers the app's XPC clients restrict their sessions to.
    static let servicePeers = ["decoder", "parser", "fetcher", "gifs", "voice"]
    public static func hasServicePeers(_ bundle: Bundle = .main) -> Bool {
        guard let peers = bundle.object(forInfoDictionaryKey: "SereinXPCPeers") as? [String: String] else { return false }
        return servicePeers.allSatisfy { !(peers[$0] ?? "").isEmpty }
    }

    @MainActor public static func requireConfinement() {
        guard isBundled, !(isConfined() && hasServicePeers()) else { return }
        let alert = NSAlert()
        alert.messageText = "Serein is not sandboxed"
        alert.informativeText = "This copy of Serein is not running under its App Sandbox profile, or lacks the code-signing requirements of its services, so it will not start."
        alert.alertStyle = .critical
        alert.runModal()
        exit(78)
    }
}

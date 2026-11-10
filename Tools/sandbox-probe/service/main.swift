// A probe XPC service signed with the profile under test: it tries what the profile must deny
// and reports each outcome ("allowed" or "denied") to the host.
import Foundation
import IOKit
import Network
import Security

func probes() -> String {
    var out: [String] = []
    func check(_ what: String, _ f: () throws -> Bool) {
        let ok = (try? f()) ?? false
        out.append("\(ok ? "allowed" : "denied"): \(what)")
    }
    let fm = FileManager.default
    check("read a system file") { fm.contents(atPath: "/System/Library/CoreServices/SystemVersion.plist") != nil }
    check("read /etc/hosts") { fm.contents(atPath: "/etc/hosts") != nil }
    check("list /Users") { try !fm.contentsOfDirectory(atPath: "/Users").isEmpty }
    check("list the home directory") { try !fm.contentsOfDirectory(atPath: ServiceSandbox.realHome).isEmpty }
    check("list ~/Documents") { try !fm.contentsOfDirectory(atPath: ServiceSandbox.realHome + "/Documents").isEmpty }
    check("write its container") { fm.createFile(atPath: NSTemporaryDirectory() + "probe", contents: Data([1])) }
    check("write /tmp") { fm.createFile(atPath: "/private/tmp/signalsafe-probe", contents: Data([1])) }
    check("run /usr/bin/true") {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return true
    }
    check("write preferences") {
        let d = UserDefaults(suiteName: "org.signalsafe.sandbox-probe")
        d?.set(1, forKey: "k")
        return d?.synchronize() ?? false
    }
    let sem = DispatchSemaphore(value: 0)
    nonisolatedReady(sem) { ok in out.append("\(ok ? "allowed" : "denied"): tcp to 127.0.0.1") }
    // HTTPS to the web (DNS, TLS trust, the network stack): only the web-facing profiles and
    // the app may.
    let web = DispatchSemaphore(value: 0)
    let got = Box()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    URLSession(configuration: config).dataTask(with: URL(string: "https://www.apple.com/library/test/success.html")!) { _, response, _ in
        got.result = response != nil
        web.signal()
    }.resume()
    _ = web.wait(timeout: .now() + 20)
    out.append("\(got.result ? "allowed" : "denied"): https to the web")
    // Other programs' Mach services (the pasteboard server stands for all of them).
    check("look up a Mach service") {
        // CFMessagePortCreateRemote is a bootstrap lookup: nil when it is refused.
        CFMessagePortCreateRemote(nil, "com.apple.pasteboard.1" as CFString) != nil
    }
    // Devices: an IOKit user client (IOSurface, which any unsandboxed process may open).
    check("open an IOKit device") {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOSurfaceRoot"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return false }
        IOServiceClose(connect)
        return true
    }
    // The services compile their peers' code-signing requirements (NSXPCConnection does it
    // when the requirement is set): this must work under every profile.
    check("compile a code-signing requirement") {
        var req: SecRequirement?
        return SecRequirementCreateWithString("identifier \"org.signalsafe.SignalSafe\"" as CFString, [], &req) == errSecSuccess && req != nil
    }
    // Each real service runs its own check at start-up; under its profile it must pass.
    out.append("\(ServiceSandbox.isConfined() ? "allowed" : "denied"): pass the offline services' start-up check")
    out.append("\(ServiceSandbox.isConfined(network: true) ? "allowed" : "denied"): pass the web services' start-up check")
    return out.joined(separator: "\n")
}

/// Allowed only if the connection becomes ready; refused (the port is closed) or "Operation not
/// permitted" both mean no traffic left, but only EPERM means the sandbox stopped it.
func nonisolatedReady(_ sem: DispatchSemaphore, _ report: (Bool) -> Void) {
    let box = Box()
    let c = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    c.stateUpdateHandler = { s in
        switch s {
        case .ready: box.result = true; sem.signal()
        case .failed(let e), .waiting(let e):
            if case .posix(let code) = e, code == .ECONNREFUSED { box.result = true }
            sem.signal()
        default: break
        }
    }
    c.start(queue: .global())
    _ = sem.wait(timeout: .now() + 3)
    c.cancel()
    report(box.result)
}

final class Box { var result = false }

final class Probe: NSObject, ProbeProtocol {
    func run(reply: @escaping (String) -> Void) { reply(probes()) }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // As the real services do: every message is checked against the host's requirement
        // (under the profile, so a profile that breaks the check shows up as missing probes).
        c.setCodeSigningRequirement("identifier \"org.signalsafe.SignalSafe\"")
        c.exportedInterface = NSXPCInterface(with: ProbeProtocol.self)
        c.exportedObject = Probe()
        c.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

// A probe XPC service signed with the profile under test: it tries what the profile must deny
// and reports each outcome ("allowed" or "denied") to the host.
import Foundation
import Network

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
    check("list the home directory") { try !fm.contentsOfDirectory(atPath: NSHomeDirectoryForUser(NSUserName()) ?? "/").isEmpty }
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

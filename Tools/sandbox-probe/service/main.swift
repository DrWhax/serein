// A probe XPC service signed with the profile under test: it tries what the profile must deny
// and reports each outcome ("allowed" or "denied") to the host. Compiled with
// MediaXPCInterface's sources, so it listens exactly as the real services do.
import AudioToolbox
import Foundation
import IOKit
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
    // UDP, as WebRTC sends media: to a documentation address (192.0.2.1, nothing answers) and
    // to this machine. Only EPERM means the sandbox refused (an unreachable network is not it).
    check("send udp") { udp(to: "192.0.2.1") }
    check("send udp to 127.0.0.1") { udp(to: "127.0.0.1") }
    check("bind a udp port") {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r == 0
    }
    // The audio input runs (the audio system's services and devices), and hears something.
    // It opens the microphone for half a second and keeps nothing. Without the microphone (no
    // entitlement, or Serein.sb's deny) the input still runs but hears exact silence, as it
    // also does when the user never allowed the microphone to whatever started this check.
    // CoreAudio itself crashes (CAAppWorkArounds::CSCheckFix) where no system file can be read:
    // there it cannot run at all, which is reported without starting it.
    let systemReadable = fm.contents(atPath: "/System/Library/CoreServices/SystemVersion.plist") != nil
    let (frames, peak) = systemReadable ? listen() : (0, 0)
    out.append("\(frames > 0 ? "allowed" : "denied"): start the audio input")
    out.append("\(peak > 0 ? "allowed" : "denied"): hear the microphone")
    // Each real service runs its own check at start-up; under its profile it must pass.
    out.append("\(ServiceSandbox.isConfined() ? "allowed" : "denied"): pass the start-up check without system files")
    out.append("\(ServiceSandbox.isConfined(systemFiles: true) ? "allowed" : "denied"): pass the start-up check with system files")
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

final class Box: @unchecked Sendable { var result = false }   // set before the semaphore it waits on

final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var n = 0
    var top: Float = 0
    func add(_ k: Int, _ level: Float) { lock.lock(); n += k; top = max(top, level); lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return n }
    var peak: Float { lock.lock(); defer { lock.unlock() }; return top }
}

/// Half a second of the default input through an audio queue (CoreAudio's C API, which reports
/// a refused service as an error where AVAudioEngine raises): frames delivered, peak level.
func listen() -> (Int, Float) {
    var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 4,
                                             mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    let heard = Counter()
    var queue: AudioQueueRef?
    let made = AudioQueueNewInputWithDispatchQueue(&queue, &format, 0, DispatchQueue(label: "probe.audio")) { q, buffer, _, _, _ in
        let n = Int(buffer.pointee.mAudioDataByteSize) / 4
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(samples[i])) }
        heard.add(n, peak)
        AudioQueueEnqueueBuffer(q, buffer, 0, nil)
    }
    guard made == noErr, let q = queue else { return (0, 0) }
    defer { AudioQueueDispose(q, true) }
    for _ in 0..<3 {
        var b: AudioQueueBufferRef?
        if AudioQueueAllocateBuffer(q, 4096, &b) == noErr, let b { AudioQueueEnqueueBuffer(q, b, 0, nil) }
    }
    guard AudioQueueStart(q, nil) == noErr else { return (0, 0) }
    Thread.sleep(forTimeInterval: 0.5)
    AudioQueueStop(q, true)
    return (heard.total, heard.peak)
}

/// One datagram to `host`:9; false only when the sandbox refused it.
func udp(to host: String) -> Bool {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(9).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)
    let byte: [UInt8] = [0]
    let n = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    return n == 1 || (errno != EPERM && errno != EACCES)
}

struct Probe: XPCMessageHandler {
    var maxRequestBytes: Int { 0 }
    func reply(to request: XPCMessage) async throws -> XPCMessage { XPCMessage(payload: Data(probes().utf8)) }
}

// As the real services do: every session is checked against the host's requirement (under the
// profile, so a profile that breaks the check shows up as missing probes). The service name
// comes from the executable (Probe<profile>): the offline profiles let only the real
// service's bundle be read, so this one cannot read its own Info.plist.
let profile = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.dropFirst("Probe".count)
XPCServer.serve("org.signalsafe.sandbox-probe.\(profile)", requirement: XPCPeer.requirement(identifier: "org.signalsafe.SignalSafe", sameTeam: false), Probe())

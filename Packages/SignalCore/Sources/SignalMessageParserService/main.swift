// SignalMessageParser.xpc: decrypted message content, contact-sync records, sticker manifests
// and link-and-sync backups are parsed here, never in the app, and not by this process either:
// each session (one source of messages, MessageParser.swift) gets a SignalMessageParserChild
// process of its own, which inherits this process's sandbox and ends with the session
// (ParserChild.swift). Neither holds keys or has a database, network or files: App Sandbox plus
// the Seatbelt rules of Sandbox/SignalMessageParser.sb, which both require to be in force.
//
// This process stays while it has sessions and for 30 s after the last (launchd delays starting
// a service again for ten seconds after one that ran briefly), then exits.

import Foundation
import MediaXPCInterface
import MessageParsing
import Synchronization

ServiceSandbox.requireConfinement("SignalMessageParser", memoryLimit: 1024 * 1024 * 1024)

let childExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SignalMessageParserChild")
let pool = ParserChildPool { try ParserChildProcess.spawn(childExecutable) }
/// Sessions open now; at most `maxSessions` (the app keeps one per parser client).
let open = Atomic<Int>(0)
let maxSessions = 8
/// Which idle spell the exit timer belongs to (a new session starts another).
let idle = Atomic<Int>(0)

func sessionEnded() {
    guard open.subtract(1, ordering: .relaxed).newValue == 0 else { return }
    pool.drain()
    let spell = idle.add(1, ordering: .relaxed).newValue
    Task(name: "parser idle exit") {
        guard (try? await Task.sleep(for: .seconds(30))) != nil else { return }
        if open.load(ordering: .relaxed) == 0, idle.load(ordering: .relaxed) == spell { exit(0) }
    }
}

XPCServer.serve(XPCMessageParser.serviceName, requirement: XPCPeer.required(.app, by: "SignalMessageParser")) {
    guard open.add(1, ordering: .relaxed).newValue <= maxSessions else {
        sessionEnded()
        throw MediaProcessingError.unsupportedFormat
    }
    _ = idle.add(1, ordering: .relaxed)
    do {
        return ParserChildSession(child: try pool.take(), start: { try ParserChildProcess.spawn(childExecutable) }, onEnd: sessionEnded)
    } catch {
        sessionEnded()
        throw error
    }
}

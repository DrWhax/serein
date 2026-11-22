import AppKit
import SignalSafeSystem

// The built app runs under App Sandbox plus its Seatbelt rules (Sandbox/Serein.sb); if they
// are not in force it does not start (fails closed). `swift run` builds are not bundled.
AppSandbox.requireConfinement()

// The release smoke test runs the production XPC handshake before any account is opened.
if CommandLine.arguments.contains("--check-calling-service") {
    exit(CallingLink.checkService() ? EXIT_SUCCESS : EXIT_FAILURE)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

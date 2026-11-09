// SignalMediaDecoder.xpc: the sandboxed media decoder. Signed with App Sandbox plus the Seatbelt
// rules of Sandbox/SignalMediaDecoder.sb (Tools/build-app.sh puts them in its entitlements): no
// files, network, processes, Mach services or preferences; it is handed bytes over its XPC
// connection and returns pixels, samples and encoded files. It refuses to serve unless that
// profile is in force. Tools/build-app.sh bundles it into SignalSafe.app/Contents/XPCServices.

import Foundation
import MediaXPCInterface
import SignalMediaDecoder

ServiceSandbox.requireConfinement("SignalMediaDecoder")

let delegate = MediaXPCListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

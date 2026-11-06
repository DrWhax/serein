// SignalMediaDecoder.xpc: the sandboxed media decoder (App Sandbox, no other entitlements —
// no network, no files beyond what it is sent). Tools/build-app.sh bundles it into
// SignalSafe.app/Contents/XPCServices.

import Foundation
import SignalMediaDecoder

let delegate = MediaXPCListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

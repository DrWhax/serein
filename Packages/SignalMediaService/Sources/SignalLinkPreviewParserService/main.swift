// SignalLinkPreviewParser.xpc: parses link-preview HTML and nothing else. Signed with App
// Sandbox plus the Seatbelt rules of Sandbox/SignalLinkPreviewParser.sb (Tools/build-app.sh puts
// them in its entitlements); it refuses to serve unless that profile is in force.

import Foundation
import LinkPreviewParser
import MediaXPCInterface

ServiceSandbox.requireConfinement("SignalLinkPreviewParser")
let delegate = LinkPreviewXPCListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

// SignalCalling.xpc runs the Swift calling engine. Signed with App Sandbox plus the Seatbelt
// rules of Packages/SignalMediaService/Sandbox/SignalCalling.sb: outgoing network (media and
// signalling paths, never this machine's own services) and the microphone; no user files, no
// writes, no programs. It refuses to serve unless that profile is in force, only the app may
// connect, and it exits when the app's session ends.

import CallService
import CallXPC
import Foundation
import MediaXPCInterface
import SwiftCallingServiceAdapter

#if os(Linux)
import CLinuxCallNetwork
if CommandLine.arguments.dropFirst().elementsEqual(["--linux-call-socket-broker"]) {
    ServiceSandbox.requireConfinement("SignalCallingSocketBroker", systemFiles: true)
    exit(call_net_serve_broker())
}
guard call_net_start_broker() != 0 else {
    FileHandle.standardError.write(Data("SignalCalling: could not start confined socket broker\n".utf8))
    exit(78)
}
#endif
ServiceSandbox.requireConfinement("SignalCalling", systemFiles: true)

let handler = CallXPCHandler(makeEndpoint: SwiftVoiceEndpoint.factory, onSessionEnd: { exit(0) })
XPCServer.serve(RemoteCallEndpoint.serviceName, requirement: XPCPeer.required(.app, by: "SignalCalling"), handler)

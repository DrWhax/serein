// SignalCalling.xpc: ringrtc (WebRTC) for the app's calls, apart from everything else the app
// holds. Signed with App Sandbox plus the Seatbelt rules of
// Packages/SignalMediaService/Sandbox/SignalCalling.sb: outgoing network (WebRTC's media and
// signalling paths, never this machine's own services) and the microphone; no user files, no
// writes, no programs. It refuses to serve unless that profile is in force, only the app may
// connect, and it exits when the app's session ends.

import CallService
import CallXPC
import Foundation
import MediaXPCInterface

ServiceSandbox.requireConfinement("SignalCalling", systemFiles: true)

XPCServer.serve(RemoteCallEndpoint.serviceName, requirement: XPCPeer.required(.app, by: "SignalCalling"), CallXPCHandler(onSessionEnd: { exit(0) }))

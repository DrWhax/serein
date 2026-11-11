// SignalVoiceNoteEncoder.xpc: encodes the voice notes the app records to MP3. Signed with App
// Sandbox plus the Seatbelt rules of Sandbox/SignalVoiceNoteEncoder.sb (no files, network,
// processes, Mach services or preferences); it refuses to serve unless that profile is in
// force, and only the app may connect.

import Foundation
import MediaXPCInterface
import VoiceNoteEncoder

ServiceSandbox.requireConfinement("SignalVoiceNoteEncoder")

XPCServer.serve(MediaXPCClient.voiceServiceName, requirement: XPCPeer.required(.app, by: "SignalVoiceNoteEncoder"), VoiceNoteXPCHandler())

// SignalVoiceNoteEncoder.xpc: records voice notes from the microphone and encodes them to MP3.
// Signed with App Sandbox plus the Seatbelt rules of Sandbox/SignalVoiceNoteEncoder.sb (the
// microphone, the audio system's services and system files; no user files, no writes, no
// network, processes or preferences);
// it refuses to serve unless that profile is in force, only the app may connect, and it exits
// (the microphone off, any recording discarded) when the app's session ends.

import Foundation
import MediaXPCInterface
import VoiceNoteService

ServiceSandbox.requireConfinement("SignalVoiceNoteEncoder", systemFiles: true)

XPCServer.serve(MediaXPCClient.voiceServiceName, requirement: XPCPeer.required(.app, by: "SignalVoiceNoteEncoder"), VoiceNoteXPCHandler(onSessionEnd: { exit(0) }))

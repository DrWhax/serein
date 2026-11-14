// SignalMessageParser.xpc: parses decrypted message content, contact-sync records, sticker
// manifests and link-and-sync backups (gunzip from CodecCore; MessageParsing) and nothing else. It holds no keys and has no database, network or
// files: App Sandbox plus the Seatbelt rules of Sandbox/SignalMessageParser.sb, which it requires
// to be in force. It serves one session (one source of messages, MessageParser.swift) and exits
// when that session ends.

import CodecCore
import Foundation
import MediaXPCInterface
import MessageParsing

ServiceSandbox.requireConfinement("SignalMessageParser")
final class OneSession: XPCMessageHandler {
    let inner = MessageParserXPCHandler(inflate: { gzip in
        Data(try Gzip.decompress(ByteSlice([UInt8](gzip)), maxOutput: MessageParserLimits.maxBackupBytes))
    })
    var maxRequestBytes: Int { inner.maxRequestBytes }
    func reply(to request: XPCMessage) async throws -> XPCMessage { try await inner.reply(to: request) }
    func sessionEnded() { exit(0) }
}
XPCServer.serve(XPCMessageParser.serviceName, requirement: XPCPeer.required(.app, by: "SignalMessageParser"), singleSession: true, OneSession())

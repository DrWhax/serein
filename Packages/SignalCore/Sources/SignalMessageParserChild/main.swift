// SignalMessageParserChild: one source's parser (ParserChild.swift), started by
// SignalMessageParser.xpc for one session and ended with it. It inherits the service's sandbox
// (no keys, database, network or files; Sandbox/SignalMessageParser.sb) and checks it is in
// force before reading a request. Requests come on stdin and replies go to stdout, as frames.

import CodecCore
import Foundation
import MediaXPCInterface
import MessageParsing

/// Link-and-sync backups are inflated as they stream in (BackupStreaming.swift). Primaries pad
/// the gzip member with zeros to hide its length.
extension GzipStream: BackupInflater {}

ServiceSandbox.requireConfinement("SignalMessageParserChild")
let handler = MessageParserXPCHandler(inflater: { GzipStream(allowsZeroPadding: true) })
ParserChild.serve(input: .standardInput, output: .standardOutput, handler: handler)
exit(0)

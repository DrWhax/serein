// SignalMessageParserChild: one source's parser (ParserChild.swift), started by
// SignalMessageParser.xpc for one session and ended with it. It inherits the service's sandbox
// (no keys, database, network or files; Sandbox/SignalMessageParser.sb) and checks it is in
// force before reading a request. Requests come on stdin and replies go to stdout, as frames.

import CodecCore
import Foundation
import MediaXPCInterface
import MessageParsing

ServiceSandbox.requireConfinement("SignalMessageParserChild")
let handler = MessageParserXPCHandler(inflate: { gzip in
    Data(try Gzip.decompress(ByteSlice([UInt8](gzip)), maxOutput: MessageParserLimits.maxBackupBytes))
})
ParserChild.serve(input: .standardInput, output: .standardOutput, handler: handler)
exit(0)

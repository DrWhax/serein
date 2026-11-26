#if os(Linux)
import LinuxServiceTransport

extension ParserChildProcess {
    public static func supervised() throws -> ParserChildProcess {
        let channel = try LinuxParserChannel()
        return ParserChildProcess(requests: channel.stream, replies: channel.stream,
                                  isRunning: { channel.isRunning }, stop: { channel.stop() },
                                  outcome: { channel.isRunning ? nil : "parser child exited" })
    }
}
#endif

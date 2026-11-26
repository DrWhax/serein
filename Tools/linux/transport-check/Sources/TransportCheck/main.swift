import Foundation
import MediaXPCInterface

struct TestService: XPCMessageHandler {
    let maxRequestBytes = 256 * 1024
    func reply(to request: XPCMessage) async throws -> XPCMessage {
        let bytes = try request.requirePayload()
        if bytes == Data([0xfe]) { try await Task.sleep(for: .seconds(3)) }
        return XPCMessage(payload: bytes)
    }
}

let name = MediaXPCClient.serviceName
if CommandLine.arguments.dropFirst().first == "service" {
    XPCServer.serve(name, requirement: .app, TestService())
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}
struct CheckFailure: Error { let message: String }

let channel = XPCChannel(.service(name), peer: .decoder, timeout: .seconds(5))
func echo(_ data: Data) throws {
    let reply = try channel.sendSync(data, timeout: .seconds(5), maxReply: data.count)
    try check(reply == data, "reply corrupted or delivered to the wrong caller")
}

try echo(Data())
try echo(Data(repeating: 0x7a, count: 200_000))
try await withThrowingTaskGroup(of: Void.self) { group in
    for i in 0..<8 {
        group.addTask { try echo(Data(repeating: UInt8(i), count: 8192 + i)) }
    }
    try await group.waitForAll()
}

do {
    _ = try channel.sendSync(Data([0xfe]), timeout: .milliseconds(80), maxReply: 1)
    throw CheckFailure(message: "deadline did not expire")
} catch XPCServiceError.timedOut {}
try echo(Data([1, 2, 3]))

do {
    _ = try channel.sendSync(Data([4, 5]), timeout: .seconds(5), maxReply: 1)
    throw CheckFailure(message: "oversized reply accepted")
} catch MediaProcessingError.invalidResult {}

for target in [XPCChannel(.service(name), peer: .voice, timeout: .seconds(1)),
               XPCChannel(.service(MediaXPCClient.voiceServiceName), peer: .voice, timeout: .seconds(1))] {
    do {
        _ = try target.sendSync(Data(), timeout: .seconds(1), maxReply: 0)
        throw CheckFailure(message: "client connected without the designated route")
    } catch XPCServiceError.lost {}
}
channel.reset()
try echo(Data([1]))
print("PASS: separate processes, concurrent and bounded replies, timeout recovery, peer roles, missing route and reset")

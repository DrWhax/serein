import Foundation
import MediaXPCInterface
import LinkPreviewParser
import VoiceNoteService

struct TestService: XPCMessageHandler {
    let maxRequestBytes = 256 * 1024
    func reply(to request: XPCMessage) async throws -> XPCMessage {
        let bytes = try request.requirePayload()
        if bytes == Data([0xfe]) { try await Task.sleep(for: .seconds(3)) }
        return XPCMessage(payload: bytes)
    }
}

/// Supplies a fixed page at the network boundary and delegates its HTML to
/// the production parser handler in another process.
struct FixtureFetcher: XPCMessageHandler {
    let maxRequestBytes = LinkPreviewFetchRequest.maxBytes
    func reply(to request: XPCMessage) async throws -> XPCMessage {
        guard let endpoint = request.endpoint else { throw MediaProcessingError.invalidResult }
        let body = try request.requirePayload()
        guard case .page = try Wire.decode(LinkPreviewFetchRequest.self, body, maxBytes: maxRequestBytes) else {
            throw MediaProcessingError.invalidResult
        }
        let parser = LinkPreviewParserClient(.endpoint(endpoint), peer: .parser)
        let html = Data("<html><head><title>Linux service test</title></head></html>".utf8)
        let parsed = try await parser.linkPreviewHTML(html, httpCharset: nil)
        let preview = parsed.map { FetchedLinkPreview(title: $0.title, description: $0.description,
                                                      date: nil, imageHref: nil, image: nil) }
        return XPCMessage(payload: try Wire.encode(preview))
    }
}

let name = MediaXPCClient.serviceName
switch CommandLine.arguments.dropFirst().first {
case "confined":
    let preview = try await LinkPreviewFetcherClient(timeout: .seconds(5)).page("https://example.invalid/")
    try check(preview?.title == "Linux service test", "confined parser did not return the title")
    let image = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let info = try await MediaXPCClient().imageInfo(image)
    try check(info.width == 3 && info.height == 2, "confined decoder did not return the image dimensions")
    print("Confined production services returned the HTML title and PNG image information.")
    exit(0)
case "service":
    XPCServer.serve(name, requirement: .app, TestService())
case "parser":
    let handler = EndpointService(requirement: .fetcher, LinkPreviewXPCHandler())
    XPCServer.serve(LinkPreviewParserClient.serviceName, requirement: .app, handler)
case "voice":
    XPCServer.serve(MediaXPCClient.voiceServiceName, requirement: .app, VoiceNoteXPCHandler())
case "fetcher":
    XPCServer.serve(LinkPreviewFetcherClient.serviceName, requirement: .app, FixtureFetcher())
default:
    break
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
               XPCChannel(.service("org.signalsafe.SignalCalling"), peer: .calling, timeout: .seconds(1))] {
    do {
        _ = try target.sendSync(Data(), timeout: .seconds(1), maxReply: 0)
        throw CheckFailure(message: "client connected without the designated route")
    } catch XPCServiceError.lost {}
}
channel.reset()
try echo(Data([1]))
print("PASS: separate processes, concurrent and bounded replies, timeout recovery, peer roles, missing route and reset")

let preview = try await LinkPreviewFetcherClient(timeout: .seconds(5)).page("https://example.invalid/")
try check(preview?.title == "Linux service test", "delegated parser did not return its decoded title")
print("PASS: app → fetcher → production HTML parser over the delegated endpoint")

// verify.py supplies known float samples through an isolated ALSA file device.
let recorder = MediaXPCClient()
let noteID = try await recorder.recordVoiceNote()
let deadline = ContinuousClock.now + .seconds(5)
var heardTone = false
while ContinuousClock.now < deadline {
    let progress = try await recorder.voiceNoteProgress(noteID)
    if progress.levels.contains(where: { $0 > 0.1 }) { heardTone = true }
    if heardTone && progress.seconds >= 0.25 { break }
    try await Task.sleep(for: .milliseconds(15))
}
let note = try await recorder.finishVoiceNote(noteID)
try check(heardTone && note.duration >= 0.25 && !note.data.isEmpty, "capture or MP3 encoding failed")
print("PASS: ALSA fixture capture, microphone level reporting and MP3 output")

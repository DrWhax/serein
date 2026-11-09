// The probe host (Tools/check-sandbox-profile.sh), compiled together with MediaXPCInterface's
// sources so it talks to the services exactly as the app does:
//   1. each probe service (one per profile) reports what it could do;
//   2. the real SignalMediaDecoder.xpc decodes every kind of media under its profile;
//   3. the real SignalLinkPreviewParser.xpc parses a page under its profile.
// Prints a line per check; exits non-zero when any XPC call fails.
// Arguments: probe service names, then "--", then media files (by extension).

import Foundation

@objc protocol ProbeHostProtocol {
    @objc(runWithReply:) func run(reply: @escaping @Sendable (String) -> Void)
}

func probe(_ name: String) async -> String {
    let c = NSXPCConnection(serviceName: name)
    c.remoteObjectInterface = NSXPCInterface(with: ProbeHostProtocol.self)
    c.resume()
    defer { c.invalidate() }
    return await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
        let once = OnceFlag()
        let proxy = c.remoteObjectProxyWithErrorHandler { e in if once.claim() { k.resume(returning: "xpc error: \(e)") } }
        guard let p = proxy as? ProbeHostProtocol else { return k.resume(returning: "xpc error: no proxy") }
        p.run { s in if once.claim() { k.resume(returning: s) } }
    }
}

var failed = false
@MainActor func check(_ what: String, _ body: () async throws -> String) async {
    do { print("ok: \(what): \(try await body())") } catch {
        print("FAILED: \(what): \(error)")
        failed = true
    }
}

let args = CommandLine.arguments.dropFirst()
let probes = args.prefix { $0 != "--" }
let files = args.drop { $0 != "--" }.dropFirst().map { URL(fileURLWithPath: $0) }

for name in probes {
    let out = await probe(name)
    print(out.split(separator: "\n").map { "\(name) \($0)" }.joined(separator: "\n"))
    if out.hasPrefix("xpc error") { failed = true }
}

let media = MediaXPCClient(timeout: .seconds(60))
for url in files {
    let bytes = try Data(contentsOf: url)
    let name = url.lastPathComponent
    switch url.pathExtension.lowercased() {
    case "png", "jpg", "gif", "webp":
        await check("\(name) imageInfo") { let i = try await media.imageInfo(bytes); return "\(i.width)×\(i.height)" }
        await check("\(name) displayImage") { let d = try await media.displayImage(bytes, maxDimension: 256); return "\(d.width)×\(d.height)" }
        await check("\(name) thumbnail") { let t = try await media.thumbnail(bytes, size: 150); return "\(t.width)×\(t.height)" }
        let type = ["png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()] ?? ""
        if type != "image/gif" {
            await check("\(name) scaleForSending") { let s = try await media.scaleForSending(bytes, contentType: type, level: .one); return "\(s.contentType) \(s.data.count) bytes" }
        }
        await check("\(name) stripMetadata") { "\(try await media.stripMetadata(bytes, contentType: type).count) bytes" }
        if type == "image/png" {
            await check("\(name) stickerImage") { let s = try await media.stickerImage(bytes); return "\(s.contentType) \(s.data.count) bytes" }
        }
    case "mp3", "m4a", "aac":
        await check("\(name) audioSummary") { let s = try await media.audioSummary(bytes); return "\(s.duration) s" }
        await check("\(name) decodeAudio") { let c = try await media.decodeAudio(bytes, startFrame: 0, maxFrames: 8192); return "\(c.samples.count) bytes of samples" }
    case "mp4":
        await check("\(name) videoInfo") { let i = try await media.videoInfo(bytes); return "\(i.width)×\(i.height)" }
        await check("\(name) posterFrame") { let p = try await media.posterFrame(bytes); return "\(p.width)×\(p.height)" }
        await check("\(name) play") {
            let (session, _) = try await media.openVideo(bytes)
            var frames = try await media.videoFrames(session, count: 8).count
            try await media.seekVideo(session, to: 0)
            frames += try await media.videoFrames(session, count: 4).count
            await media.closeVideo(session)
            return "\(frames) frames"
        }
    default:
        print("skipped: \(name)")
    }
}
await check("voice note") {
    let session = try await media.startVoiceNote(sampleRate: 44_100)
    let tone = (0..<44_100).map { Float(sin(Double($0) * 2 * Double.pi * 440 / 44_100)) * 0.3 }
    try await media.appendVoiceNote(session, samples: tone)
    let note = try await media.finishVoiceNote(session)
    return "\(note.data.count) bytes mp3"
}

let parser = LinkPreviewParserClient()
await check("link preview page") {
    let m = try await parser.linkPreviewHTML(Data("<meta property=\"og:title\" content=\"Probe page\">".utf8), httpCharset: nil)
    guard m?.title == "Probe page" else { throw MediaProcessingError.invalidResult }
    return "parsed"
}
exit(failed ? 1 : 0)

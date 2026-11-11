// The probe host (Tools/check-sandbox-profile.sh), compiled together with MediaXPCInterface's
// sources so it talks to the services exactly as the app does (and signed with the app's
// identifier, which the services require of their clients):
//   1. each probe service (one per profile) reports what it could do;
//   2. the real SignalMediaDecoder.xpc decodes every kind of media under its profile;
//   3. the real SignalLinkPreviewFetcher.xpc fetches a page (live network) and has it parsed by
//      the real SignalLinkPreviewParser.xpc, which refuses HTML from the host itself;
//   4. the real SignalGifSearch.xpc lists trending GIFs through Signal's content proxy.
// With --refused it only checks that the services turn it away (a copy signed otherwise).
// Prints a line per check; exits non-zero when any check fails.
// Arguments: probe service names, then "--", then media files (by extension).

import Foundation

/// One probe service's report (its HTTPS probe alone may take 20 s).
func probe(_ name: String) async -> String {
    do {
        let report = try await XPCChannel(.service(name), peer: nil, timeout: .seconds(120)).request(XPCMessage(), maxReply: 1 << 20) { try $0.result() }
        return String(decoding: report, as: UTF8.self)
    } catch { return "xpc error: \(error)" }
}

var failed = false
@MainActor func check(_ what: String, _ body: () async throws -> String) async {
    do { print("ok: \(what): \(try await body())") } catch {
        print("FAILED: \(what): \(error)")
        failed = true
    }
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--refused" {
    // Signed with another identifier: every service must refuse the connection.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let refusedDecoder = (try? await MediaXPCClient(timeout: .seconds(10)).imageInfo(png)) == nil
    let refusedFetcher = (try? await LinkPreviewFetcherClient(timeout: .seconds(10)).page("https://signal.org/")) == nil
    let refusedGifs = (try? await GifSearchClient(timeout: .seconds(10)).trending(limit: 1, offset: nil)) == nil
    let refusedVoice = (try? await MediaXPCClient(timeout: .seconds(10)).startVoiceNote(sampleRate: 48_000)) == nil
    print("\(refusedDecoder ? "refused" : "SERVED"): decoder; \(refusedFetcher ? "refused" : "SERVED"): fetcher; \(refusedGifs ? "refused" : "SERVED"): gifs; "
          + "\(refusedVoice ? "refused" : "SERVED"): voice notes")
    exit(refusedDecoder && refusedFetcher && refusedGifs && refusedVoice ? 0 : 1)
}
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
    case "avif":
        await check("\(name) imageInfo") { let i = try await media.imageInfo(bytes); return "\(i.width)×\(i.height)" }
        await check("\(name) displayImage") { let d = try await media.displayImage(bytes, maxDimension: 256); return "\(d.width)×\(d.height)" }
        await check("\(name) stripMetadata") { "\(try await media.stripMetadata(bytes, contentType: "image/avif").count) bytes" }
    case "heic":
        await check("\(name) convertHEIC") { let j = try await media.convertHEIC(bytes); return "\(j.width)×\(j.height) JPEG \(j.data.count) bytes" }
        await check("\(name) stripMetadata") { "\(try await media.stripMetadata(bytes, contentType: "image/heic").count) bytes" }
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
// Recording is the voice-note service's alone: the decoder, asked directly, refuses.
await check("decoder refuses voice notes") {
    let direct = MediaXPCClient(timeout: .seconds(10), voice: .service(MediaXPCClient.serviceName))
    return (try? await direct.startVoiceNote(sampleRate: 48_000)) == nil ? "refused" : "SERVED"
}

// The app's path: the fetcher fetches, the parser (reached through the endpoint the parser
// hands out) parses, and only fields come back.
let previews = LinkPreviewFetcherClient(timeout: .seconds(60))
let site = ProcessInfo.processInfo.environment["SANDBOX_CHECK_SITE"] ?? "https://signal.org/"
await check("link preview fetch") {
    guard let p = try await previews.page(site), !p.title.isEmpty else { throw MediaProcessingError.invalidResult }
    return "\(p.title.prefix(40)), image \(p.imageHref != nil)"
}
// The parser takes no HTML from the app: its service only hands out the endpoint.
await check("parser refuses html from the app") {
    let direct = LinkPreviewParserClient(.service(LinkPreviewParserClient.serviceName), timeout: .seconds(10))
    if (try? await direct.linkPreviewHTML(Data("<title>x</title>".utf8), httpCharset: nil)) != nil { throw MediaProcessingError.invalidResult }
    return "refused"
}
await check("gif search") {
    let page = try await GifSearchClient(timeout: .seconds(60)).trending(limit: 4, offset: nil)
    return "\(page.gifs.count) gifs"
}
exit(failed ? 1 : 0)

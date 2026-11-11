// Media revocation, the viewer side: `SignalSession.applyMediaAvailability` (the lightbox, the
// inline video, the playing voice note, the decoded-pixel cache) against the Lean model's
// `apply` (Verification/Media), on random viewer states and random availabilities.
//
// Run through Tools/verify-media.sh, or set SEREIN_MEDIA_ORACLE to the oracle executable.

import Foundation
import SignalCore
import SignalUI
import Testing
@testable import SignalSafe

enum MediaApplyOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Media").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_MEDIA_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func apply(_ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["apply"]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RigFailure() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

@MainActor @Suite(.serialized, .enabled(if: MediaApplyOracle.available, "build the oracle: Tools/verify-media.sh"))
struct MediaApplyConformanceTests {
    func pairs(_ xs: [(Int, Int)]) -> String { xs.isEmpty ? "-" : xs.map { "\($0.0):\($0.1)" }.joined(separator: ",") }

    @Test func randomViewers() throws {
        var seed: UInt64 = 2026
        func below(_ n: Int) -> Int {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }
        let count = ProcessInfo.processInfo.environment["SEREIN_MEDIA_CASES"].flatMap { Int($0) } ?? 2000
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<count {
            // The availability: references (message, path) of live messages.
            var refs: [(Int, Int)] = []
            for m in 0..<3 { for p in 0..<3 where below(3) == 0 { refs.append((m, p)) } }
            var state = MediaAvailability()
            for (m, p) in refs {
                state.messageIds.insert("m\(m)")
                state.paths.insert("p\(p)")
                state.messagePaths["m\(m)", default: []].insert("p\(p)")
            }
            // The viewers: a lightbox of message m with 1–2 attachments, a video, a voice note, cached files.
            let session = SignalSession()
            var lightboxCode = "-"
            if below(3) != 0 {
                let m = below(3)
                // Sometimes nothing downloaded yet (no paths): only the message itself decides.
                let ps = below(4) == 0 ? [] : (0..<(1 + below(2))).map { _ in below(3) }
                var attachments = ps.map { p -> SignalCore.MessageAttachment in
                    var a = SignalCore.MessageAttachment(contentType: "image/png", size: 4)
                    a.path = "p\(p)"
                    return a
                }
                if attachments.isEmpty { attachments = [SignalCore.MessageAttachment(contentType: "image/png", size: 4)] }
                session.lightbox = .init(messageId: "m\(m)", attachments: attachments, index: 0, authorTitle: nil, authorColor: "A200", timestamp: Date())
                lightboxCode = "\(m):" + ps.map(String.init).joined(separator: ".")
            }
            var video: [(Int, Int)] = []
            if below(2) == 0 {
                let (m, p) = (below(3), below(3))
                session.inlineVideo = (messageId: "m\(m)", player: VideoPlaybackEngine(autoDrive: false), path: "p\(p)")
                video = [(m, p)]
            }
            var audio: [(Int, Int)] = []
            if below(2) == 0 {
                let (m, p) = (below(3), below(3))
                session.activeAudioMessageId = "m\(m)"
                session.activeAudioPath = "p\(p)"
                audio = [(m, p)]
            }
            let cached = Array(Set((0..<below(4)).map { _ in below(3) })).sorted()
            for p in cached {
                session.images["p\(p)"] = RGBAImage(width: 1, height: 1, pixels: Data([0, 0, 0, 255]), scale: 1)
                session.imagePaths["p\(p)"] = "p\(p)"
            }
            lines.append("\(pairs(refs)) | \(lightboxCode) \(pairs(video)) \(pairs(audio)) \(cached.isEmpty ? "-" : cached.map(String.init).joined(separator: ","))")

            session.applyMediaAvailability(state)

            let lb = session.lightbox.map { l in
                "\(l.messageId.dropFirst()):" + l.attachments.compactMap { $0.path?.dropFirst() }.map(String.init).joined(separator: ".")
            } ?? "-"
            let v = session.inlineVideo.map { "\($0.messageId.dropFirst()):\($0.path.dropFirst())" } ?? "-"
            let au = session.activeAudioMessageId.flatMap { id in session.activeAudioPath.map { "\(id.dropFirst()):\($0.dropFirst())" } } ?? "-"
            let c = Set(session.imagePaths.values).compactMap { Int($0.dropFirst()) }.sorted()
            swift.append("\(lb) \(v) \(au) \(c.isEmpty ? "-" : c.map(String.init).joined(separator: ","))")
        }
        let model = try MediaApplyOracle.apply(lines)
        var reported = 0
        for (k, (m, s)) in zip(model, swift).enumerated() where m != s {
            reported += 1
            if reported <= 3 { Issue.record("disagree at step \(k) (\(lines[k]))\n  model \(m) | swift \(s)") }
        }
        #expect(model.count == lines.count && reported == 0, "\(reported) of \(lines.count) cases disagree")
    }
}

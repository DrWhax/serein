// Screenshot tests against Storybook captures of the upstream component
// (References/<story-id>.<theme>.png + .json, written by Tools/capture-storybook.mjs).
// The SwiftUI view is rendered at the reference's CSS size and device scale on the
// Storybook page background, then compared with pixelmatch; ≤1% differing pixels pass.
// On failure the actual image and a diff are written to .build/snapshot-failures/.

import CodecCore
import CoreGraphics
import EncodePNG
import Foundation
import ImagePNG
import SignalUI
import SwiftUI
import Testing

struct ReferenceInfo: Decodable {
    var id: String
    var theme: String
    var width: Double
    var height: Double
    var scale: Double
    var background: [Double]   // RGBA 0…255 (alpha 0…1)
    /// Portal (dialog / popover) rects in CSS px, for full-viewport captures.
    var portals: [[Double]]?
}

struct SnapshotResult {
    var differing: Int
    var total: Int
    var ratio: Double { Double(differing) / Double(max(total, 1)) }
}

enum Snapshot {
    static let maxDifferingRatio = 0.01

    static var referencesDir: URL {
        Bundle.module.url(forResource: "References", withExtension: nil)!
    }
    static var failuresDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/snapshot-failures")
    }

    static func reference(_ id: String, _ theme: String) throws -> (ReferenceInfo, PixelBuffer) {
        let base = referencesDir.appendingPathComponent("\(id).\(theme)")
        let info = try JSONDecoder().decode(ReferenceInfo.self, from: Data(contentsOf: base.appendingPathExtension("json")))
        // Trusted fixtures: the banded captures of very tall stories exceed the default limits.
        var limits = DecodeLimits()
        limits.maxDimension = 65_536
        limits.maxPixels = 256 * 1024 * 1024
        let png = try PNGDecoder.decode([UInt8](try Data(contentsOf: base.appendingPathExtension("png"))), limits: limits)
        return (info, png.stillImage)
    }

    /// Renders `view` (in the given theme, sized like the reference) to RGBA8.
    @MainActor
    static func render(_ view: some View, info: ReferenceInfo) throws -> PixelBuffer {
        AxoFonts.register()
        let bg = info.background
        let scheme: ColorScheme = info.theme == "dark" ? .dark : .light
        let content = view
            .frame(width: info.width, height: info.height, alignment: .topLeading)
            .background(Color(.sRGB, red: bg[0] / 255, green: bg[1] / 255, blue: bg[2] / 255, opacity: 1))
            .environment(\.colorScheme, scheme)
            .environment(\.axoAnimationsDisabled, true)
            .environment(\.axoStaticRendering, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = info.scale
        renderer.proposedSize = ProposedViewSize(width: info.width, height: info.height)
        if let image = renderer.cgImage, let pixels = try? rgba(image) { return pixels }
        // Very tall views (AxoSymbol All) come back as one huge CGImage without readable
        // pixels: render them in 4000pt bands, each the whole view shifted up and clipped.
        let band = 4000.0
        var rows: [UInt8] = []
        var y = 0.0
        while y < info.height {
            let h = min(band, info.height - y)
            let slice = content.offset(y: -y).frame(width: info.width, height: h, alignment: .topLeading).clipped()
            let renderer = ImageRenderer(content: slice)
            renderer.scale = info.scale
            renderer.proposedSize = ProposedViewSize(width: info.width, height: h)
            guard let image = renderer.cgImage else { throw SnapshotError.renderFailed }
            rows += try rgba(image).rgba
            y += band
        }
        let width = Int((info.width * info.scale).rounded())
        return PixelBuffer(width: width, height: rows.count / (width * 4), rgba: rows)
    }

    /// Copies the rendered pixels out of the image's own data provider (no pointer code),
    /// converting its 8-bit layout (RGBA or BGRA, alpha first/last, premultiplied) to RGBA.
    static func rgba(_ image: CGImage) throws -> PixelBuffer {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, let data = image.dataProvider?.data as Data? else {
            throw SnapshotError.unsupportedLayout("\(image.bitsPerComponent)/\(image.bitsPerPixel)")
        }
        if let name = image.colorSpace?.name as String?, name != (CGColorSpace.sRGB as String), name != (CGColorSpace.extendedSRGB as String) {
            throw SnapshotError.unsupportedLayout("colour space \(name)")
        }
        let alpha = image.alphaInfo
        let littleEndian = image.byteOrderInfo == .order32Little
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
        let bytes = [UInt8](data)
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let s = y * image.bytesPerRow + x * 4
                var p = [bytes[s], bytes[s + 1], bytes[s + 2], bytes[s + 3]]
                if littleEndian { p.reverse() }                  // now in big-endian component order
                let (a, r, g, b) = alphaFirst ? (p[0], p[1], p[2], p[3]) : (p[3], p[0], p[1], p[2])
                let av = hasAlpha ? a : 255
                func un(_ c: UInt8) -> UInt8 {
                    guard premultiplied, av > 0, av < 255 else { return c }
                    return UInt8(min(255, (Int(c) * 255 + Int(av) / 2) / Int(av)))
                }
                let d = (y * image.width + x) * 4
                out[d] = un(r); out[d + 1] = un(g); out[d + 2] = un(b); out[d + 3] = av
            }
        }
        return PixelBuffer(width: image.width, height: image.height, rgba: out)
    }

    /// The captured story root's height (points).
    static func referenceHeight(_ id: String, _ theme: String) throws -> CGFloat {
        let (info, _) = try reference(id, theme)
        return CGFloat(info.height)
    }

    /// Compares `view` with the Storybook capture of `id` in `theme`; records an issue above 1%
    /// (or a documented per-story `maxRatio` where Chromium's shaper cannot be matched).
    @MainActor
    @discardableResult
    static func assertMatches(_ view: some View, story id: String, theme: String, maxRatio: Double? = nil,
                              sourceLocation: SourceLocation = #_sourceLocation) throws -> SnapshotResult {
        let (info, expected) = try reference(id, theme)
        let actual = try render(view, info: info)
        guard actual.width == expected.width, actual.height == expected.height else {
            Issue.record("\(id).\(theme): size \(actual.width)×\(actual.height) ≠ reference \(expected.width)×\(expected.height)",
                         sourceLocation: sourceLocation)
            return SnapshotResult(differing: expected.width * expected.height, total: expected.width * expected.height)
        }
        var diff: [UInt8]? = []
        let n = PixelMatch().compare(actual.rgba, expected.rgba, width: actual.width, height: actual.height, diff: &diff)
        let result = SnapshotResult(differing: n, total: actual.width * actual.height)
        // Full-viewport portal captures are mostly uniform overlay: also require ≤1% inside
        // the portal rects (+16px), so a wrong dialog can't hide in the background.
        var regionRatio = 0.0
        if let portals = info.portals, let diff {
            var inside = 0, differing = 0
            for r in portals {
                let x0 = max(0, Int((r[0] - 16) * info.scale)), y0 = max(0, Int((r[1] - 16) * info.scale))
                let x1 = min(actual.width, Int((r[0] + r[2] + 16) * info.scale)), y1 = min(actual.height, Int((r[1] + r[3] + 16) * info.scale))
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let k = (y * actual.width + x) * 4
                        inside += 1
                        if diff[k] == 255 && diff[k + 1] == 0 && diff[k + 2] == 0 { differing += 1 }
                    }
                }
            }
            regionRatio = Double(differing) / Double(max(inside, 1))
            print("SNAPSHOT \(id).\(theme) portal region \(percent(regionRatio)) differing")
        }
        print("SNAPSHOT \(id).\(theme) \(percent(result.ratio)) differing")
        let limit = maxRatio ?? maxDifferingRatio
        let failed = result.ratio > limit || regionRatio > limit
        if failed || ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"] != nil {
            try FileManager.default.createDirectory(at: failuresDir, withIntermediateDirectories: true)
            let base = failuresDir.appendingPathComponent("\(id).\(theme)")
            try Data(PNGEncoder.encode(actual)).write(to: base.appendingPathExtension("actual.png"))
            try Data(PNGEncoder.encode(expected)).write(to: base.appendingPathExtension("expected.png"))
            if let diff { try Data(PNGEncoder.encode(PixelBuffer(width: actual.width, height: actual.height, rgba: diff))).write(to: base.appendingPathExtension("diff.png")) }
        }
        if failed {
            let base = failuresDir.appendingPathComponent("\(id).\(theme)")
            Issue.record("\(id).\(theme): \(n) of \(result.total) pixels differ (\(percent(result.ratio)) > \(percent(limit))) — see \(base.path).*.png",
                         sourceLocation: sourceLocation)
        }
        return result
    }
}

enum SnapshotError: Error { case renderFailed, unsupportedLayout(String) }

/// "1.23%" without C varargs formatting.
func percent(_ ratio: Double) -> String {
    let hundredths = Int((ratio * 10000).rounded())
    let frac = hundredths % 100
    return "\(hundredths / 100).\(frac < 10 ? "0" : "")\(frac)%"
}

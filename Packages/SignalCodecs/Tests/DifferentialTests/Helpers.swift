// Shared test-only helpers. ImageIO/CoreGraphics appear only in this test target.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import CodecCore

enum Resources {
    static let root: URL = Bundle.module.resourceURL!.appendingPathComponent("Resources")
    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func bytes(_ path: String) -> [UInt8] { [UInt8](try! Data(contentsOf: url(path))) }
    static func text(_ path: String) -> String { String(decoding: bytes(path), as: UTF8.self) }
    static func files(_ dir: String, _ filter: (String) -> Bool = { _ in true }) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(dir).path)) ?? []).filter(filter).sorted()
    }
}

func md5Hex(_ bytes: [UInt8]) -> String {
    Insecure.MD5.hash(data: Data(bytes)).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

/// Fixed-point formatting without C varargs (String(format:) is unsafe under -strict-memory-safety).
func fixed(_ x: Double, _ digits: Int) -> String {
    x.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
}

/// Premultiplied RGBA8 in sRGB, as CoreGraphics renders it.
struct OracleFrame { var width: Int; var height: Int; var rgba: [UInt8] }

enum ImageIOOracle {
    static func frameCount(_ bytes: [UInt8]) -> Int {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    static func frame(_ bytes: [UInt8], index: Int, applyOrientation: Bool = false) -> OracleFrame? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, index, nil) else { return nil }
        return render(img)
    }

    static func render(_ img: CGImage) -> OracleFrame? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // Test oracle only: CoreGraphics renders into our buffer through a raw pointer.
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = unsafe CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? OracleFrame(width: w, height: h, rgba: buf) : nil
    }

    /// EXIF/TIFF orientation ImageIO reports for frame 0 (1 if absent).
    static func orientation(_ bytes: [UInt8]) -> Int {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 1 }
        return (props[kCGImagePropertyOrientation] as? Int) ?? 1
    }
}

func premultiplied(_ p: PixelBuffer) -> [UInt8] {
    var out = p.rgba
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Int(out[i + 3])
        for k in 0..<3 { out[i + k] = UInt8((Int(out[i + k]) * a + 127) / 255) }
    }
    return out
}

struct Difference: CustomStringConvertible {
    var maxError = 0
    var meanError = 0.0
    var samplesOverTolerance = 0
    var description: String { "max \(maxError), mean \(fixed(meanError, 3)), over-tolerance \(samplesOverTolerance)" }
}

func compare(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Difference {
    precondition(a.count == b.count)
    var d = Difference()
    var sum = 0
    for i in 0..<a.count {
        let e = abs(Int(a[i]) - Int(b[i]))
        sum += e
        d.maxError = max(d.maxError, e)
        if e > tolerance { d.samplesOverTolerance += 1 }
    }
    d.meanError = a.isEmpty ? 0 : Double(sum) / Double(a.count)
    return d
}

/// Compact mismatch description: first differing pixel and count (no array dumps).
func mismatch(_ a: PixelBuffer, _ b: PixelBuffer) -> String {
    guard a.width == b.width && a.height == b.height else { return "size \(a.width)x\(a.height) vs \(b.width)x\(b.height)" }
    var first: (Int, Int)?
    var n = 0
    for i in stride(from: 0, to: a.rgba.count, by: 4) where a.rgba[i..<(i + 4)] != b.rgba[i..<(i + 4)] {
        n += 1
        if first == nil { first = ((i / 4) % a.width, (i / 4) / a.width) }
    }
    guard let (x, y) = first else { return "identical" }
    let pa = a.pixel(x: x, y: y), pb = b.pixel(x: x, y: y)
    return "\(n) pixels differ; first at \(x),\(y): \([pa.r, pa.g, pa.b, pa.a]) vs \([pb.r, pb.g, pb.b, pb.a])"
}

// `handleSave`: the document drawn at full size (zoom 1, no overlays) and encoded as JPEG at
// Chromium's default canvas quality (0.92), with a blurhash of a ≤200px rendering
// (`imageToBlurHash`). Upstream encodes JPEG (canvasToBytes' default type) but labels it
// image/png; here it is labelled image/jpeg.

import Blurhash
import CodecCore
import EncodeJPEG
import SwiftUI

/// `MediaEditorResultType`
public struct MediaEditorResult: Sendable, Equatable {
    public var data: Data
    public var contentType: String
    public var width: Int
    public var height: Int
    public var blurHash: String
    public var caption: String?
    public var isViewOnce: Bool
    public var isHighQuality: Bool
}

enum MediaEditorExport {
    static let quality = 92

    @MainActor
    static func render(_ doc: MediaEditorSnapshot, background: MediaEditorBitmap, scale: CGFloat = 1) -> PixelBuffer? {
        let w = max(1, doc.image.width.rounded()), h = max(1, doc.image.height.rounded())
        let renderer = MediaEditorRenderer(background: background)
        let view = Canvas { ctx, _ in renderer.draw(doc, in: ctx, zoom: 1) }
            .frame(width: w, height: h)
            .background(Color.black)
        let r = ImageRenderer(content: view)
        r.scale = scale
        r.proposedSize = ProposedViewSize(width: w, height: h)
        guard let cg = r.cgImage else { return nil }
        return pixels(cg)
    }

    /// The rendered pixels as RGBA (from the image's own data provider, any 8-bit layout).
    static func pixels(_ image: CGImage) -> PixelBuffer? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, let data = image.dataProvider?.data as Data? else { return nil }
        let alpha = image.alphaInfo
        let little = image.byteOrderInfo == .order32Little
        let first = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let bytes = [UInt8](data)
        var out = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let s = y * image.bytesPerRow + x * 4, d = (y * image.width + x) * 4
                var p = (bytes[s], bytes[s + 1], bytes[s + 2], bytes[s + 3])
                if little { p = (p.3, p.2, p.1, p.0) }
                var (r, g, b, a) = first ? (p.1, p.2, p.3, p.0) : (p.0, p.1, p.2, p.3)
                if alpha == .noneSkipFirst || alpha == .noneSkipLast || alpha == .none { a = 255 }
                if premultiplied, a != 0, a != 255 {
                    r = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                    g = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                    b = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                }
                out[d] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = a
            }
        }
        return PixelBuffer(width: image.width, height: image.height, rgba: out)
    }

    @MainActor
    static func export(_ doc: MediaEditorSnapshot, background: MediaEditorBitmap, caption: String, isViewOnce: Bool, isHighQuality: Bool) -> MediaEditorResult? {
        guard let full = render(doc, background: background) else { return nil }
        let jpeg = JPEGEncoder.encode(full, quality: quality)
        let longest = max(doc.image.width, doc.image.height)
        let small = longest > 200 ? render(doc, background: background, scale: 200 / longest) : full
        let hash = small.map { Blurhash.encode($0) } ?? ""
        return MediaEditorResult(data: Data(jpeg), contentType: "image/jpeg", width: full.width, height: full.height, blurHash: hash,
                                 caption: caption.isEmpty ? nil : caption, isViewOnce: isViewOnce, isHighQuality: isHighQuality)
    }
}

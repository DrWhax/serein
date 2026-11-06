// The one audited `unsafe` for outgoing call video (approved 2026-11-06; Tools/lint-codecs.sh
// allows exactly this line): CoreVideo has no safe way to read a pixel buffer, so the planes of
// a local camera or ScreenCaptureKit frame (NV12, never untrusted input) are copied out whole
// (bytesPerRow × rows from each plane's base address) while the buffer is locked read-only. Everything after the copy is safe
// Swift over [UInt8]: each plane's size and stride are checked against the frame before its
// rows are packed (stride padding dropped) into the tight NV12 layout ringrtc takes.

import CoreVideo

/// A packed NV12 frame for ringrtc: the Y plane (width × height), then interleaved CbCr
/// (width × height/2). Width and height are even.
public struct CapturedFrame: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var nv12: [UInt8]

    public init?(width: Int, height: Int, nv12: [UInt8]) {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, width <= 8192, height <= 8192,
              nv12.count == width * height * 3 / 2 else { return nil }
        self.width = width
        self.height = height
        self.nv12 = nv12
    }
}

public enum CaptureFrames {
    /// 4:2:0 bi-planar formats (video and full range) the capture outputs are configured for.
    static let nv12Formats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]

    /// The frame in `buffer`, packed; nil for another format or an inconsistent layout.
    public static func pack(_ buffer: CVPixelBuffer) -> CapturedFrame? {
        guard nv12Formats.contains(CVPixelBufferGetPixelFormatType(buffer)), CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var planes: [(rows: Int, width: Int, stride: Int, bytes: [UInt8])] = []
        for i in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, i), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, i)
            guard rows > 0, rows <= 8192, stride > 0, stride <= 65536 else { return nil }
            guard let bytes = unsafe CVPixelBufferGetBaseAddressOfPlane(buffer, i).map({ unsafe Array(UnsafeRawBufferPointer(start: $0, count: rows * stride)) }) else { return nil }
            planes.append((rows, CVPixelBufferGetWidthOfPlane(buffer, i), stride, bytes))
        }
        return pack(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), planes: planes)
    }

    /// Packs copied planes (Y, then CbCr with 2-byte samples) after checking every size.
    static func pack(width w: Int, height h: Int, planes: [(rows: Int, width: Int, stride: Int, bytes: [UInt8])]) -> CapturedFrame? {
        guard w > 0, h > 0, w % 2 == 0, h % 2 == 0, w <= 8192, h <= 8192, planes.count == 2 else { return nil }
        let y = planes[0], uv = planes[1]
        // Row bytes per plane: Y is w samples of 1 byte, CbCr is w/2 samples of 2 bytes.
        guard y.width == w, y.rows == h, uv.width == w / 2, uv.rows == h / 2,
              y.stride >= w, uv.stride >= w,
              y.bytes.count >= y.stride * (h - 1) + w, uv.bytes.count >= uv.stride * (h / 2 - 1) + w else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(w * h * 3 / 2)
        for r in 0..<h { out.append(contentsOf: y.bytes[(r * y.stride)..<(r * y.stride + w)]) }
        for r in 0..<(h / 2) { out.append(contentsOf: uv.bytes[(r * uv.stride)..<(r * uv.stride + w)]) }
        return CapturedFrame(width: w, height: h, nv12: out)
    }
}

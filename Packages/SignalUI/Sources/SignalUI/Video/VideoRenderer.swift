// Draws decoded video frames (8-bit I420 from the media service) with Metal: the three planes
// as r8 textures, Y′CbCr → RGB in the fragment shader (BT.601 / BT.709, limited or full
// range, as the stream's VUI says), aspect-fit into the target with the track's clockwise
// rotation, the rest cleared to the background colour.

import Metal
import QuartzCore

/// A frame as the renderer takes it.
public struct VideoPlanes: Sendable, Equatable {
    public var width: Int, height: Int
    public var y: [UInt8], u: [UInt8], v: [UInt8]
    public var fullRange: Bool
    /// matrix_coefficients (1 BT.709, 5/6 BT.601, 9 BT.2020, 2 unspecified: by size).
    public var matrix: Int
    /// transfer_characteristics (16 PQ, 18 HLG: shown tone-mapped to SDR; others SDR gamma).
    public var transfer: Int
    public var time: Double
    /// 8: a byte per sample; 9–12: two (little-endian), keeping 10-bit HDR's precision.
    public var bitDepth: Int

    public init(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8], fullRange: Bool, matrix: Int, time: Double, transfer: Int = 1, bitDepth: Int = 8) {
        self.transfer = transfer
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.y = y
        self.u = u
        self.v = v
        self.fullRange = fullRange
        self.matrix = matrix
        self.time = time
    }

    public var isValid: Bool {
        let cw = (width + 1) / 2, ch = (height + 1) / 2, b = bitDepth > 8 ? 2 : 1
        return (8...12).contains(bitDepth) && width > 0 && height > 0 && width <= 8192 && height <= 8192 && y.count == width * height * b
            && u.count == cw * ch * b && v.count == cw * ch * b
    }
}

/// A packed RGBA frame (remote call video, already rotated by ringrtc).
public struct RGBAFrame: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
    public var isValid: Bool { width > 0 && height > 0 && width <= 8192 && height <= 8192 && pixels.count == width * height * 4 }
}

@MainActor
public final class VideoRenderer {
    public let device: any MTLDevice
    let queue: any MTLCommandQueue
    let sampler: any MTLSamplerState
    let pixelFormat: MTLPixelFormat
    /// Pipelines per (quarter turns, colour mode, full range): the parameters are compiled in, so
    /// no constant buffers (whose Metal APIs take raw pointers) are needed.
    var pipelines: [Int: any MTLRenderPipelineState] = [:]

    /// The shader's colour handling: BT.601, BT.709, BT.2020 SDR, BT.2020 HLG / PQ (to SDR).
    public enum Colour: Int, Sendable { case bt601 = 0, bt709 = 1, bt2020 = 2, hlg = 3, pq = 4 }

    public static func colour(matrix: Int, transfer: Int, height: Int) -> Colour {
        if matrix == 9 || matrix == 10 { return transfer == 18 ? .hlg : transfer == 16 ? .pq : .bt2020 }
        return matrix == 1 || (matrix == 2 && height > 576) ? .bt709 : .bt601
    }

    /// `bitDepth` > 8: samples arrive as r16 (value / 65535) and are scaled to the 8-bit
    /// normalisation the constants below use (a 10-bit code v is the 8-bit v / 4).
    static func shader(rotation: Int, colour: Colour, fullRange: Bool, rgba: Bool = false, mirrored: Bool = false, bitDepth: Int = 8) -> String {
        let scale = bitDepth > 8 ? 65535.0 / (Double(1 << (bitDepth - 8)) * 255.0) : 1.0
        return """
        #include <metal_stdlib>
        using namespace metal;
        #define RGBA_INPUT \(rgba ? 1 : 0)
        #define MIRRORED \(mirrored ? 1 : 0)
        #define ROTATION \(rotation)
        #define COLOUR \(colour.rawValue)
        #define FULL_RANGE \(fullRange ? 1 : 0)
        #define SAMPLE_SCALE \(scale)
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out videoVertex(uint vid [[vertex_id]]) {
            float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
            Out o;
            o.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
            // Display corner → texture coordinate for a clockwise rotation.
            float2 t = corner;
        #if ROTATION == 1
            t = float2(corner.y, 1.0 - corner.x);
        #elif ROTATION == 2
            t = float2(1.0 - corner.x, 1.0 - corner.y);
        #elif ROTATION == 3
            t = float2(1.0 - corner.y, corner.x);
        #endif
        #if MIRRORED
            t.x = 1.0 - t.x;
        #endif
            o.uv = t;
            return o;
        }
        fragment float4 videoFragment(Out in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tu [[texture(1)]],
                                      texture2d<float> tv [[texture(2)]], sampler s [[sampler(0)]]) {
        #if RGBA_INPUT
            return float4(ty.sample(s, in.uv).rgb, 1.0);
        #endif
            float y = ty.sample(s, in.uv).r * SAMPLE_SCALE, cb = tu.sample(s, in.uv).r * SAMPLE_SCALE - 128.0 / 255.0,
                  cr = tv.sample(s, in.uv).r * SAMPLE_SCALE - 128.0 / 255.0;
        #if FULL_RANGE
            float l = y, k = 1.0;
        #else
            float l = (y - 16.0 / 255.0) * (255.0 / 219.0), k = 255.0 / 224.0;
        #endif
        #if COLOUR == 1
            float3 rgb = float3(l + 1.5748 * k * cr, l - 0.1873 * k * cb - 0.4681 * k * cr, l + 1.8556 * k * cb);
        #elif COLOUR >= 2
            // BT.2020 non-constant luminance.
            float3 rgb = float3(l + 1.4746 * k * cr, l - 0.16455 * k * cb - 0.57135 * k * cr, l + 1.8814 * k * cb);
        #else
            float3 rgb = float3(l + 1.402 * k * cr, l - 0.344136 * k * cb - 0.714136 * k * cr, l + 1.772 * k * cb);
        #endif
        #if COLOUR >= 3
            rgb = clamp(rgb, 0.0, 1.0);
            float3 lin;
        #if COLOUR == 3
            // HLG (BT.2100): inverse OETF to scene light, then the OOTF (system gamma 1.2 at
            // 1000 cd/m²) to display light relative to the 1000 cd/m² peak.
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            float3 scene = select(exp((rgb - c) / a) + b, rgb * rgb * 3.0, rgb <= 0.5) / 12.0;
            float ys = dot(scene, float3(0.2627, 0.6780, 0.0593));
            lin = scene * pow(max(ys, 1e-6), 0.2) * (1000.0 / 203.0);
        #else
            // PQ (SMPTE ST 2084): inverse EOTF to absolute light, relative to 203 cd/m².
            const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            float3 e = pow(rgb, 1.0 / m2);
            lin = pow(max(e - c1, 0.0) / (c2 - c3 * e), 1.0 / m1) * (10000.0 / 203.0);
        #endif
            // SDR white at 203 cd/m²: midtones unchanged, highlights above 0.8 roll off smoothly
            // (continuous slope) towards 1.0.
            float lumIn = dot(lin, float3(0.2627, 0.6780, 0.0593));
            float lumOut = lumIn <= 0.8 ? lumIn : 0.8 + 0.2 * (1.0 - exp(-(lumIn - 0.8) / 0.2));
            lin *= lumIn > 0.0 ? lumOut / lumIn : 0.0;
            // BT.2020 → BT.709 primaries, then the BT.709 / BT.1886 display gamma.
            float3x3 toRec709 = float3x3(float3(1.6605, -0.1246, -0.0182), float3(-0.5876, 1.1329, -0.1006), float3(-0.0728, -0.0083, 1.1187));
            rgb = pow(clamp(toRec709 * lin, 0.0, 1.0), 1.0 / 2.4);
        #endif
            return float4(clamp(rgb, 0.0, 1.0), 1.0);
        }
        """
    }

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.device = device
        self.queue = queue
        self.sampler = sampler
        self.pixelFormat = pixelFormat
    }

    func pipeline(rotation: Int, colour: Colour, fullRange: Bool, rgba: Bool = false, mirrored: Bool = false, bitDepth: Int = 8) -> (any MTLRenderPipelineState)? {
        let key = rotation + colour.rawValue * 4 + (fullRange ? 32 : 0) + (rgba ? 64 : 0) + (mirrored ? 128 : 0) + bitDepth * 256
        if let p = pipelines[key] { return p }
        let source = Self.shader(rotation: rotation, colour: colour, fullRange: fullRange, rgba: rgba, mirrored: mirrored, bitDepth: bitDepth)
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vf = library.makeFunction(name: "videoVertex"), let ff = library.makeFunction(name: "videoFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = pixelFormat
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipelines[key] = p
        return p
    }

    /// How a frame fills the target: contained (letterboxed) or covering it (cropped).
    public enum Fit: Sendable { case contain, cover }

    /// The rectangle (x, y, w, h in target pixels) of a frame shown with `rotation`; for
    /// `.cover` it overhangs the target, and rasterisation clips it to the target.
    static func fitRect(frameWidth: Int, frameHeight: Int, rotation: Int, targetWidth: Int, targetHeight: Int, fit: Fit = .contain) -> (Double, Double, Double, Double) {
        let fw = Double(rotation % 180 == 0 ? frameWidth : frameHeight), fh = Double(rotation % 180 == 0 ? frameHeight : frameWidth)
        let tw = Double(max(1, targetWidth)), th = Double(max(1, targetHeight))
        let scale = fit == .contain ? min(tw / fw, th / fh) : max(tw / fw, th / fh)
        let w = (fw * scale).rounded(), h = (fh * scale).rounded()
        return (((tw - w) / 2).rounded(.down), ((th - h) / 2).rounded(.down), w, h)
    }

    /// Encodes the drawing of `frame` into `target` (cleared to `background` first).
    public func draw(_ frame: VideoPlanes, rotation: Int, into target: any MTLTexture, fit: Fit = .contain, mirrored: Bool = false,
                     background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) -> (any MTLCommandBuffer)? {
        let colour = Self.colour(matrix: frame.matrix, transfer: frame.transfer, height: frame.height)
        let deep = frame.bitDepth > 8
        let format: VideoTexture.Format = deep ? .r16 : .r8
        guard frame.isValid,
              let pipe = pipeline(rotation: (rotation / 90) & 3, colour: colour, fullRange: frame.fullRange, mirrored: mirrored, bitDepth: deep ? frame.bitDepth : 8),
              let ty = VideoTexture.make(device, plane: frame.y, width: frame.width, height: frame.height, format: format),
              let tu = VideoTexture.make(device, plane: frame.u, width: (frame.width + 1) / 2, height: (frame.height + 1) / 2, format: format),
              let tv = VideoTexture.make(device, plane: frame.v, width: (frame.width + 1) / 2, height: (frame.height + 1) / 2, format: format),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let r = Self.fitRect(frameWidth: frame.width, frameHeight: frame.height, rotation: rotation, targetWidth: target.width, targetHeight: target.height, fit: fit)
        enc.setViewport(MTLViewport(originX: r.0, originY: r.1, width: r.2, height: r.3, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipe)
        enc.setFragmentTexture(ty, index: 0)
        enc.setFragmentTexture(tu, index: 1)
        enc.setFragmentTexture(tv, index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return cb
    }


    /// Encodes the drawing of an RGBA frame (remote call video) into `target`.
    public func draw(_ frame: RGBAFrame, into target: any MTLTexture, fit: Fit = .contain, mirrored: Bool = false,
                     background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) -> (any MTLCommandBuffer)? {
        guard frame.isValid, let pipe = pipeline(rotation: 0, colour: .bt601, fullRange: true, rgba: true, mirrored: mirrored),
              let t = VideoTexture.make(device, plane: frame.pixels, width: frame.width, height: frame.height, format: .rgba8),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let r = Self.fitRect(frameWidth: frame.width, frameHeight: frame.height, rotation: 0, targetWidth: target.width, targetHeight: target.height, fit: fit)
        enc.setViewport(MTLViewport(originX: r.0, originY: r.1, width: r.2, height: r.3, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipe)
        enc.setFragmentTexture(t, index: 0)
        enc.setFragmentTexture(t, index: 1)
        enc.setFragmentTexture(t, index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return cb
    }
}

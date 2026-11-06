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
    /// H.264 matrix_coefficients (1 BT.709, 5/6 BT.601, 2 unspecified: by size).
    public var matrix: Int
    public var time: Double

    public init(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8], fullRange: Bool, matrix: Int, time: Double) {
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
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        return width > 0 && height > 0 && width <= 8192 && height <= 8192 && y.count == width * height && u.count == cw * ch && v.count == cw * ch
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
    /// Pipelines per (quarter turns, BT.709, full range): the parameters are compiled in, so
    /// no constant buffers (whose Metal APIs take raw pointers) are needed.
    var pipelines: [Int: any MTLRenderPipelineState] = [:]

    static func shader(rotation: Int, bt709: Bool, fullRange: Bool, rgba: Bool = false, mirrored: Bool = false) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        #define RGBA_INPUT \(rgba ? 1 : 0)
        #define MIRRORED \(mirrored ? 1 : 0)
        #define ROTATION \(rotation)
        #define BT709 \(bt709 ? 1 : 0)
        #define FULL_RANGE \(fullRange ? 1 : 0)
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
            float y = ty.sample(s, in.uv).r, cb = tu.sample(s, in.uv).r - 128.0 / 255.0, cr = tv.sample(s, in.uv).r - 128.0 / 255.0;
        #if FULL_RANGE
            float l = y, k = 1.0;
        #else
            float l = (y - 16.0 / 255.0) * (255.0 / 219.0), k = 255.0 / 224.0;
        #endif
        #if BT709
            float3 rgb = float3(l + 1.5748 * k * cr, l - 0.1873 * k * cb - 0.4681 * k * cr, l + 1.8556 * k * cb);
        #else
            float3 rgb = float3(l + 1.402 * k * cr, l - 0.344136 * k * cb - 0.714136 * k * cr, l + 1.772 * k * cb);
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

    func pipeline(rotation: Int, bt709: Bool, fullRange: Bool, rgba: Bool = false, mirrored: Bool = false) -> (any MTLRenderPipelineState)? {
        let key = rotation * 4 + (bt709 ? 2 : 0) + (fullRange ? 1 : 0) + (rgba ? 64 : 0) + (mirrored ? 128 : 0)
        if let p = pipelines[key] { return p }
        guard let library = try? device.makeLibrary(source: Self.shader(rotation: rotation, bt709: bt709, fullRange: fullRange, rgba: rgba, mirrored: mirrored), options: nil),
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
        let bt709 = frame.matrix == 1 || (frame.matrix == 2 && frame.height > 576)
        guard frame.isValid, let pipe = pipeline(rotation: (rotation / 90) & 3, bt709: bt709, fullRange: frame.fullRange, mirrored: mirrored),
              let ty = VideoTexture.make(device, plane: frame.y, width: frame.width, height: frame.height),
              let tu = VideoTexture.make(device, plane: frame.u, width: (frame.width + 1) / 2, height: (frame.height + 1) / 2),
              let tv = VideoTexture.make(device, plane: frame.v, width: (frame.width + 1) / 2, height: (frame.height + 1) / 2),
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
        guard frame.isValid, let pipe = pipeline(rotation: 0, bt709: false, fullRange: true, rgba: true, mirrored: mirrored),
              let t = VideoTexture.make(device, plane: frame.pixels, width: frame.width, height: frame.height, rgba: true),
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

// The one audited `unsafe` for video display (approved 2026-11-05; Tools/lint-codecs.sh allows
// exactly this line): Metal has no safe way to fill a texture, so validated planes (their byte
// counts checked against the texture size below) are copied in with MTLTexture.replace, which
// reads exactly bytesPerRow × height bytes from the array. Planes are r8 (I420 video) or
// rgba8 (remote call video from ringrtc).

import Metal

enum VideoTexture {
    /// An r8Unorm (1 byte per pixel) or rgba8Unorm (4) texture holding `plane` (width × height
    /// pixels, row-major, no padding).
    static func make(_ device: any MTLDevice, plane: [UInt8], width: Int, height: Int, rgba: Bool = false) -> (any MTLTexture)? {
        let bpp = rgba ? 4 : 1
        guard width > 0, height > 0, width <= 8192, height <= 8192, plane.count == width * height * bpp else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: rgba ? .rgba8Unorm : .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        unsafe t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: plane, bytesPerRow: width * bpp)
        return t
    }
}

import CryptoKit
import Foundation
import Testing
import VideoVP9

@Suite struct VP9VideoTests {
    /// Test patterns encoded by the independent libvpx 1.15.2 vpxenc.
    /// Hashes cover every visible sample produced by vpxdec --rawvideo --i420.
    @Test func nativeMovingPictures() throws {
        try verify("motion", count: 16, sha256: "786f4a809448a856e5832d0a3ddbd41202db3256f6856ea9f2b7a3f45390435e")
    }

    @Test func oddCroppedPicturesAndAltRef() throws {
        try verify("odd", count: 18, sha256: "2f4e53a5b2d2bb9546150f4d15799923f6a7905ffdbe93866cba0713a6b9d617")
        try verify("movie", count: 24, sha256: "ad5a7343c6275a9ac0c0850ca03b89b711dbcb4dfcafb77071b288653d513e32")
    }

    @Test func multipleTileRowsAndColumns() throws {
        try verify("tile", count: 12, sha256: "9b19a754cda72a5517c2665a7ecfd717a5e7d99ce8eeea30d022373bf5cac382")
    }

    /// Four tile columns (libvpx 1.17 real time, -tile-columns 2, 1024x96, adapting): the
    /// columns decode on separate threads into their own strips and counts, which are joined
    /// afterwards. Hash from the libvpx decoder.
    @Test func fourTileColumnsDecodeIndependently() throws {
        try verify("tiles4", count: 10, sha256: "66e001571297c2c4cfce9df5e784810762ff68da7b8957d39363378f9472a3d0")
    }

    @Test func cyclicRefreshAndHighQuantizers() throws {
        try verify("segment", count: 19, sha256: "cf56776c1c7a7f2ffeb1476c41eb81a3d6bedf1cba4b016e5fbe4e6be7c6b402")
    }

    /// WebRTC-style real time from libvpx 1.17.0 (ffmpeg libvpx-vp9: deadline realtime, cpu-used 8,
    /// no lag, cyclic refresh, 300 kb/s) with frame_parallel_decoding_mode 0, so probabilities
    /// adapt backward from each frame's counts, as in calls from stock Android. At 480x270 the
    /// bottom superblocks are partial: libvpx counts an edge partition as the whole symbol, and
    /// counts the unread high-precision MV bit as 1 in frames that allow high precision. Either
    /// count wrong desynchronised every later frame. Hashes from the libvpx decoder.
    @Test func backwardAdaptationAtPictureEdges() throws {
        try verify("adapt-edge", count: 24, sha256: "8a797c153b059c71cd8797e3eacb8fbf6d33057e72529c8db89be543a045de15")
    }

    /// Swift-encoded spatial layers with libvpx-decoded reference pixels.
    /// Quantization removes every coefficient in some inter blocks whose signaled skip is zero.
    @Test func quantizedInterLayerSkipContext() throws {
        try verify("quantized-svc", count: 4, sha256: "daf9ae668145610185919641d23125700f5d019d5c0c5a7fcb55813ad18cb588")
    }

    private func verify(_ name: String, count: Int, sha256: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ivf", subdirectory: "Resources"))
        let bytes = [UInt8](try Data(contentsOf: url))
        var pos = 32, frames = 0, digest = SHA256(), decoder = VP9VideoDecoder()
        while pos < bytes.count {
            try #require(bytes.count-pos >= 12)
            let size = (0..<4).reduce(0) { $0 | (Int(bytes[pos+$1]) << (8*$1)) }
            pos += 12
            try #require(size <= bytes.count-pos)
            let frame = try decoder.decode(Array(bytes[pos..<(pos+size)]))
            pos += size
            guard let frame else { continue }
            frames += 1
            for (plane,stride,width,height) in [
                (frame.y,frame.yStride,frame.width,frame.height),
                (frame.u,frame.uvStride,(frame.width+1)/2,(frame.height+1)/2),
                (frame.v,frame.uvStride,(frame.width+1)/2,(frame.height+1)/2)
            ] {
                for row in 0..<height { digest.update(data: Data(plane[(row*stride)..<(row*stride+width)])) }
            }
        }
        #expect(frames == count)
        let hex = digest.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == sha256)
    }
}

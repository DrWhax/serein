// The player asks for frames no larger than its view shows them (the media service scales them
// before they cross to the app), and fetches a paused frame again when the view grows.

import Testing
@testable import SignalUI

/// 400x200 frames at 30 fps, scaled to the fit asked for (as the media service does).
actor ScalingVideo: VideoFrameSource {
    var next = 0
    var fits: [VideoDisplaySize?] = []
    var seeks: [Double] = []

    func frames(_ n: Int) async throws -> [VideoPlanes] { try await frames(n, fitting: nil) }

    func frames(_ n: Int, fitting size: VideoDisplaySize?) async throws -> [VideoPlanes] {
        fits.append(size)
        let (w, h) = size?.frameSize(width: 400, height: 200, rotation: 0) ?? (400, 200)
        let out = (next ..< min(60, next + n)).map { i in
            VideoPlanes(width: w, height: h, y: Array(repeating: UInt8(i), count: w * h), u: Array(repeating: 128, count: w * h / 4),
                        v: Array(repeating: 128, count: w * h / 4), fullRange: true, matrix: 2, time: Double(i) / 30, decodedWidth: 400, decodedHeight: 200)
        }
        next += out.count
        return out
    }

    func seek(to seconds: Double) async throws {
        seeks.append(seconds)
        next = Int((seconds * 30 + 1e-9).rounded(.down))
    }
}

@MainActor
@Suite struct VideoDisplaySizeTests {
    @Test func framesComeAtTheViewsSize() async {
        let src = ScalingVideo()
        let clock = Clock()
        let e = VideoPlaybackEngine(now: { clock.t }, autoDrive: false)
        await e.load(src, duration: 2, rotation: 0)
        // Before a view says how large it is, frames come as decoded.
        #expect(e.currentFrame?.width == 400)
        e.setDisplaySize(VideoDisplaySize(width: 100, height: 100))
        await e.play()
        for k in 1 ... 20 { clock.t = Double(k) / 30; await e.step() }
        #expect(await src.fits.last == VideoDisplaySize(width: 100, height: 100))
        #expect(e.currentFrame?.width == 100 && e.currentFrame?.height == 50 && e.currentFrame?.decodedWidth == 400)
        #expect(e.currentFrame?.isValid == true)
    }

    @Test func aPausedFrameIsFetchedAgainWhenTheViewGrows() async throws {
        let src = ScalingVideo()
        let e = VideoPlaybackEngine(now: { 0 }, autoDrive: false)
        e.setDisplaySize(VideoDisplaySize(width: 100, height: 100))
        await e.load(src, duration: 2, rotation: 0)
        #expect(e.currentFrame?.width == 100)
        // Smaller still: the frame on screen is sharp enough, nothing is fetched again.
        e.setDisplaySize(VideoDisplaySize(width: 60, height: 60))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await src.seeks.isEmpty)
        // Larger (a window resized step by step): once it settles, the frame comes again at the new size.
        for w in [120, 150, 180, 200] { e.setDisplaySize(VideoDisplaySize(width: w, height: 300)) }
        for _ in 0..<40 where e.currentFrame?.width != 200 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await src.seeks == [0])
        #expect(e.currentFrame?.width == 200 && e.currentFrame?.height == 100 && e.currentTime == 0)
        // Shown at more than half its size: as decoded, and no further fetch once it is.
        e.setDisplaySize(VideoDisplaySize(width: 1000, height: 1000))
        for _ in 0..<40 where e.currentFrame?.width != 400 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(e.currentFrame?.width == 400)
        e.setDisplaySize(VideoDisplaySize(width: 2000, height: 2000))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await src.seeks.count == 2)
    }

    @Test func playingDoesNotRefetch() async throws {
        let src = ScalingVideo()
        let clock = Clock()
        let e = VideoPlaybackEngine(now: { clock.t }, autoDrive: false)
        e.setDisplaySize(VideoDisplaySize(width: 100, height: 100))
        await e.load(src, duration: 2, rotation: 0)
        await e.play()
        // While playing, a larger view gets larger frames as they are fetched, without a seek.
        e.setDisplaySize(VideoDisplaySize(width: 200, height: 200))
        for k in 1 ... 30 { clock.t = Double(k) / 30; await e.step() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await src.seeks.isEmpty)
        #expect(e.currentFrame?.width == 200)
    }

    /// The same sizes MediaXPCInterface's VideoFit gives (SignalMediaDecoderTests.sizesForAFit).
    @Test func sizesMatchTheService() {
        let fit = VideoDisplaySize(width: 600, height: 400)
        #expect(fit.frameSize(width: 3594, height: 2152, rotation: 0) == (600, 360))
        #expect(fit.frameSize(width: 320, height: 240, rotation: 0) == (320, 240))
        #expect(fit.frameSize(width: 3594, height: 2152, rotation: 90) == (400, 240))
        #expect(VideoDisplaySize(width: 600, height: 400, cover: true).frameSize(width: 3594, height: 2152, rotation: 0) == (668, 400))
        #expect(VideoDisplaySize(width: 16, height: 16).frameSize(width: 4000, height: 10, rotation: 0) == (16, 2))
        #expect(VideoDisplaySize(width: 2880, height: 1800).frameSize(width: 3594, height: 2152, rotation: 0) == (3594, 2152))
        #expect(VideoDisplaySize(width: 1797, height: 1076).frameSize(width: 3594, height: 2152, rotation: 0).width < 3594)
    }

    @Test func anUnspecifiedMatrixGoesByTheDecodedSize() {
        // A 1080p frame scaled to 480 lines is still BT.709 (matrix 2: by size).
        #expect(VideoRenderer.colour(matrix: 2, transfer: 1, height: 1080) == .bt709)
        let f = VideoPlanes(width: 4, height: 2, y: Array(repeating: 0, count: 8), u: [128, 128], v: [128, 128], fullRange: false, matrix: 2, time: 0,
                            decodedWidth: 1920, decodedHeight: 1080)
        #expect(f.isValid && f.decodedHeight == 1080)
        // A decoded size smaller than the frame is not a frame.
        var bad = f
        bad.decodedWidth = 2
        #expect(!bad.isValid)
    }
}

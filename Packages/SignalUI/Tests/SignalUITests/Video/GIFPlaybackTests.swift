import Testing
@testable import SignalUI

@Suite struct GIFPlaybackTests {
    @Test func rules() {
        var p = GIFPlayback()
        // Without tap-to-play it plays while focused.
        #expect(p.shouldPlay(tapToPlay: false, focused: true, loopCount: 9, currentTime: 50, duration: 3))
        #expect(!p.shouldPlay(tapToPlay: false, focused: false, loopCount: 0, currentTime: 0, duration: 3))
        // Tap-to-play starts paused (playTime = MAX_GIF_TIME).
        #expect(!p.shouldPlay(tapToPlay: true, focused: true, loopCount: 0, currentTime: 0, duration: 3))
        p.tappedAtLoop = 2
        #expect(p.shouldPlay(tapToPlay: true, focused: true, loopCount: 2, currentTime: 0, duration: 3))
        // 3 s GIF: stops 8 s after the tap (two loops + 2 s).
        #expect(p.shouldPlay(tapToPlay: true, focused: true, loopCount: 4, currentTime: 1.9, duration: 3))
        #expect(!p.shouldPlay(tapToPlay: true, focused: true, loopCount: 4, currentTime: 2.0, duration: 3))
        // 1 s GIF: stops at the start of the fifth loop.
        #expect(p.shouldPlay(tapToPlay: true, focused: true, loopCount: 5, currentTime: 0.9, duration: 1))
        #expect(!p.shouldPlay(tapToPlay: true, focused: true, loopCount: 6, currentTime: 0, duration: 1))
        #expect(!p.shouldPlay(tapToPlay: true, focused: false, loopCount: 2, currentTime: 0, duration: 1))
    }
}

import Foundation
import SignalCore
import SignalUI
import Testing
@testable import SignalSafe

/// The timeline's animated images share `animationCacheBytes`; the oldest past it show their
/// first frame until another conversation opens.
@MainActor @Suite struct AnimationCacheTests {
    /// `frames` frames of a side × side image (side 2048: 16 MiB a frame).
    func animation(side: Int, frames: Int) -> RGBAImage {
        RGBAImage(width: side, height: side, frames: Data(count: side * side * 4 * frames), delays: Array(repeating: 100, count: frames),
                  plays: 0, scale: 2)
    }

    @Test func theOldestAnimationsFreezeAndThawWhenAConversationOpens() throws {
        let session = SignalSession()
        // 64 MiB each: four fit in 256 MiB, the fifth pushes out the first.
        for i in 0..<5 { session.storeImage(animation(side: 2048, frames: 4), key: "anim:\(i)") }
        let first = try #require(session.images["anim:0"])
        #expect(first.animation == nil && first.width == 2048)
        #expect((1..<5).allSatisfy { session.images["anim:\($0)"]?.animation != nil })
        #expect(session.frozenAnimations == ["anim:0"] && session.animations.map(\.key) == ["anim:1", "anim:2", "anim:3", "anim:4"])
        #expect(session.animations.reduce(0) { $0 + $1.bytes } == 4 * 64 << 20)
        // Stills do not count.
        session.storeImage(RGBAImage(width: 1, height: 1, pixels: Data(count: 4)), key: "still")
        #expect(session.animations.count == 4)
        // Another conversation: the frozen one decodes again when it is next shown.
        session.selectedConversationId = "other"
        #expect(session.images["anim:0"] == nil && session.frozenAnimations.isEmpty)
        #expect(session.images["anim:1"]?.animation != nil)
    }

    @Test func oneAnimationOverTheBudgetStays() {
        let session = SignalSession()
        session.storeImage(animation(side: 2048, frames: 17), key: "big")
        #expect(session.images["big"]?.animation != nil && session.frozenAnimations.isEmpty)
    }

    @Test func revokedAnimationsLeaveTheBudget() {
        let session = SignalSession()
        session.storeImage(animation(side: 64, frames: 2), key: "anim:p")
        session.imagePaths["anim:p"] = "p"
        session.applyMediaAvailability(MediaAvailability())
        #expect(session.images["anim:p"] == nil && session.animations.isEmpty)
    }

    @Test func onlyTypesWithAnAnimatedFormAskForFrames() {
        #expect(["image/gif", "image/png", "image/APNG", "image/webp"].allSatisfy(SignalSession.mayAnimate))
        #expect(!["image/jpeg", "image/avif", "image/bmp", "video/mp4"].contains(where: SignalSession.mayAnimate))
    }
}

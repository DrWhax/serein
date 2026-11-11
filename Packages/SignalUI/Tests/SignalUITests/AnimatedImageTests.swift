import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor @Suite struct AnimatedImageTests {
    /// 1×1 frames, frame i's red channel = i.
    func image(_ delays: [Int], plays: Int = 0) -> RGBAImage {
        var frames = Data()
        for i in delays.indices { frames += [UInt8(i), 0, 0, 255] }
        return RGBAImage(width: 1, height: 1, frames: frames, delays: delays, plays: plays, scale: 2)
    }

    @Test func framesAreSplitAndTheFirstIsThePixels() throws {
        let a = image([100, 200, 300])
        let anim = try #require(a.animation)
        #expect(anim.frames.map { $0[$0.startIndex] } == [0, 1, 2])
        #expect(a.pixels == anim.frames[0] && a.byteCount == 12)
        #expect(a.still.animation == nil && a.still.pixels == a.pixels && a.still.scale == 2)
        // One frame is a still image.
        #expect(image([100]).animation == nil)
    }

    /// Chromium: 10 ms or less is 100 ms.
    @Test func shortDurationsAreClamped() throws {
        let anim = try #require(image([0, 10, 11, 50]).animation)
        #expect(anim.durations == [100, 100, 11, 50])
    }

    @Test func framesFollowTheDurationsAndLoop() throws {
        let anim = try #require(image([100, 200, 300]).animation)
        let expected = [(0, 0), (99, 0), (100, 1), (299, 1), (300, 2), (599, 2), (600, 0), (700, 1), (6000 + 450, 2), (-5, 0)]
        for (ms, i) in expected { #expect(anim.frame(atMilliseconds: ms) == i, "\(ms) ms") }
        #expect(anim.nextChange(afterMilliseconds: 0) == 100)
        #expect(anim.nextChange(afterMilliseconds: 100) == 300)
        #expect(anim.nextChange(afterMilliseconds: 599) == 600)
        #expect(anim.nextChange(afterMilliseconds: 650) == 700)
    }

    /// Two plays, then the last frame stays.
    @Test func aFinitePlayCountEndsOnTheLastFrame() throws {
        let anim = try #require(image([100, 100], plays: 2).animation)
        #expect(anim.frame(atMilliseconds: 250) == 0 && anim.frame(atMilliseconds: 399) == 1)
        #expect(anim.frame(atMilliseconds: 400) == 1 && anim.frame(atMilliseconds: 10_000) == 1)
        #expect(anim.nextChange(afterMilliseconds: 250) == 300)
        #expect(anim.nextChange(afterMilliseconds: 300) == nil && anim.nextChange(afterMilliseconds: 5000) == nil)
        // A count whose end overflows plays forever.
        let long = try #require(image([65_535_000, 65_535_000], plays: Int(UInt32.max)).animation)
        #expect(long.nextChange(afterMilliseconds: 0) == 65_535_000)
    }

    @Test func theScheduleVisitsEveryChange() throws {
        let anim = try #require(image([100, 200], plays: 2).animation)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let dates = Array(AnimationSchedule(start: start, animation: anim).entries(from: start.addingTimeInterval(0.05), mode: .normal))
        #expect(dates.map { Int(($0.timeIntervalSince(start) * 1000).rounded()) } == [50, 100, 300, 400])
        // Each date shows the frame that starts then.
        #expect(dates.map { anim.frame(at: $0, start: start) } == [0, 1, 0, 1])
    }

    final class Seen { var frames: [Int] = [] }

    /// In a window, SwiftUI drives the schedule: every frame is shown, and an animated
    /// `PixelImage` lays out like a still one. (The order is `theScheduleVisitsEveryChange`'s.)
    @Test func aTimelineViewPlaysTheFrames() async throws {
        let anim = try #require(image([100, 100, 100], plays: 0).animation)
        let start = Date()
        let seen = Seen()
        let probe = TimelineView(AnimationSchedule(start: start, animation: anim)) { context in
            let i = anim.frame(at: context.date, start: start)
            let _ = seen.frames.last == i ? () : seen.frames.append(i)
            Color.clear
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: HStack { probe.frame(width: 16, height: 16); PixelImage(image([100, 100])).frame(width: 16, height: 16) })
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Under load (the whole suite in parallel) updates come late, and a late update shows the
        // frame of its moment, skipping any in between: wait for every frame, up to 15 s.
        for _ in 0..<150 where Set(seen.frames) != [0, 1, 2] || seen.frames.count < 4 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(Set(seen.frames) == [0, 1, 2] && seen.frames.count >= 4, "\(seen.frames)")
        #expect(zip(seen.frames, seen.frames.dropFirst()).allSatisfy { $0 != $1 }, "\(seen.frames)")
    }

    @Test func animationsCompareByIdentity() {
        let a = image([100, 100]), b = image([100, 100])
        #expect(a == a && a != b)
        #expect(a.still == b.still)
    }
}

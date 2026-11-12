// Clicking a voice note's play/pause button while it plays (the play head moving 20 times a
// second, as the app's audio clock moves it): real mouse events into an offscreen window.

import AppKit
import Observation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor @Observable final class FakePlayer {
    var active: AudioActive?
    var calls: [String] = []
}

struct FakeAudioBubble: View {
    let player: FakePlayer
    var body: some View {
        var a = MessageAttachment(contentType: "audio/mpeg")
        a.audioWaveform = AudioWaveform(waveform: Array(repeating: 128, count: 100), duration: 10)
        let p = player
        return MessageAudio(attachment: a, waveform: a.audioWaveform, direction: .incoming, played: false, withContentAbove: false,
                            withContentBelow: false, metadata: nil, onPlay: nil, kickOffDownload: nil, cancelDownload: nil,
                            active: player.active,
                            controls: AudioControls(playMessage: { _ in p.calls.append("playMessage") }, setPosition: { _ in p.calls.append("setPosition") },
                                                    setIsPlaying: { p.calls.append("setIsPlaying(\($0))") }, setPlaybackRate: { _ in }))
            .padding(20)
            .frame(width: 320, height: 120, alignment: .topLeading)
    }
}

/// The whole message, as the timeline draws it (with actions: hover, double-click to reply,
/// the context menu).
struct FakeAudioMessage: View {
    let player: FakePlayer
    var body: some View {
        var a = MessageAttachment(contentType: "audio/mpeg")
        a.audioWaveform = AudioWaveform(waveform: Array(repeating: 128, count: 100), duration: 10)
        var props = MessageProps(id: "m1", direction: .incoming, author: .init(id: "a", title: "Alice"), text: nil, timestamp: Date(timeIntervalSince1970: 0))
        props.attachments = [a]
        props.activeAudio = player.active
        let p = player
        props.audioControls = AudioControls(playMessage: { _ in p.calls.append("playMessage") }, setPosition: { _ in p.calls.append("setPosition") },
                                            setIsPlaying: { p.calls.append("setIsPlaying(\($0))") }, setPlaybackRate: { _ in })
        var actions = TimelineMessageActions()
        actions.reply = { p.calls.append("reply") }
        props.actions = actions
        return Message(props: props).frame(width: 600, height: 200, alignment: .topLeading)
    }
}

/// As the app draws it: a Timeline (ScrollView, LazyVStack) of rows that are `.equatable()` on
/// their message and read the playing state from an observable model while drawing.
struct FakeRow: View, Equatable {
    let id: String
    let player: FakePlayer
    nonisolated static func == (a: FakeRow, b: FakeRow) -> Bool { a.id == b.id && a.player === b.player }
    var body: some View { FakeAudioMessage(player: player) }
}

/// As the app's TimelineRow: the playing state read in the Equatable row's own body, and
/// handed down as a value.
struct FakeRowReading: View, Equatable {
    let id: String
    let player: FakePlayer
    nonisolated static func == (a: FakeRowReading, b: FakeRowReading) -> Bool { a.id == b.id && a.player === b.player }
    var body: some View { FakeAudioMessageValue(active: player.active, player: player) }
}

struct FakeAudioMessageValue: View {
    let active: AudioActive?
    let player: FakePlayer
    var body: some View {
        var a = MessageAttachment(contentType: "audio/mpeg")
        a.audioWaveform = AudioWaveform(waveform: Array(repeating: 128, count: 100), duration: 10)
        var props = MessageProps(id: "m1", direction: .incoming, author: .init(id: "a", title: "Alice"), text: nil, timestamp: Date(timeIntervalSince1970: 0))
        props.attachments = [a]
        props.activeAudio = active
        let p = player
        props.audioControls = AudioControls(playMessage: { _ in p.calls.append("playMessage") }, setPosition: { _ in p.calls.append("setPosition") },
                                            setIsPlaying: { p.calls.append("setIsPlaying(\($0))") }, setPlaybackRate: { _ in })
        var actions = TimelineMessageActions()
        actions.reply = { p.calls.append("reply") }
        props.actions = actions
        return Message(props: props).frame(width: 600, height: 200, alignment: .topLeading)
    }
}

struct FakeTimeline: View {
    let player: FakePlayer
    var readInRow = false
    var body: some View {
        Timeline(id: "c1", items: ["m0", "m1"], haveNewest: true, haveOldest: true, getTimestampForMessage: { _ in Date(timeIntervalSince1970: 0) }) { props in
            if props.id == "m1" {
                if readInRow { FakeRowReading(id: props.id, player: player).equatable() } else { FakeRow(id: props.id, player: player).equatable() }
            } else { Color.clear.frame(height: 40) }
        } renderHeroRow: {
            Color.clear.frame(height: 10)
        } renderTypingBubble: {
            EmptyView()
        }
        .frame(width: 600, height: 400)
    }
}

@MainActor @Suite(.serialized) struct AudioClickTests {
    static func click(_ window: NSWindow, at p: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
        }
    }

    func host(_ player: FakePlayer) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FakeAudioBubble(player: player))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        return window
    }

    /// The button is the 36pt circle at the bubble's leading edge (20pt padding, 2pt top).
    static let button = NSPoint(x: 20 + 18, y: 120 - (20 + 2 + 18))

    @Test func pauseWhileThePlayHeadMoves() async throws {
        let player = FakePlayer()
        player.active = AudioActive(playing: true, currentTime: 0, duration: 10, playbackRate: 1)
        let window = host(player)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        // The audio clock: the play head moves every 50 ms.
        let clock = Task { @MainActor in
            var t = 0.0
            while !Task.isCancelled {
                t += 0.05
                player.active?.currentTime = t
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { clock.cancel() }
        try await Task.sleep(for: .milliseconds(120))
        Self.click(window, at: Self.button)
        try await Task.sleep(for: .milliseconds(120))
        #expect(player.calls == ["setIsPlaying(false)"], "calls: \(player.calls)")
    }

    /// The full message: find the button by trying the left part of the bubble.
    func clickFullMessage(playing: Bool) async throws -> [String] {
        let player = FakePlayer()
        if playing { player.active = AudioActive(playing: true, currentTime: 0, duration: 10, playbackRate: 1) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: FakeAudioMessage(player: player))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let clock = Task { @MainActor in
            var t = 0.0
            while !Task.isCancelled && playing {
                t += 0.05
                player.active?.currentTime = t
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { clock.cancel() }
        // The play button: search the bubble's leading area for the point whose click calls back.
        for y in stride(from: 190.0, to: 100.0, by: -6) {
            for x in stride(from: 20.0, to: 120.0, by: 6) {
                Self.click(window, at: NSPoint(x: x, y: y))
                try await Task.sleep(for: .milliseconds(30))
                if !player.calls.isEmpty { return player.calls + ["at \(Int(x)),\(Int(y))"] }
            }
        }
        return player.calls
    }

    @Test func fullMessagePauseWhilePlaying() async throws {
        let calls = try await clickFullMessage(playing: true)
        #expect(calls.first == "setIsPlaying(false)", "calls: \(calls)")
    }

    @Test func fullMessagePlayWhenStill() async throws {
        let calls = try await clickFullMessage(playing: false)
        #expect(calls.first == "playMessage", "calls: \(calls)")
    }

    func clickInTimeline(playing: Bool, readInRow: Bool = false) async throws -> [String] {
        let player = FakePlayer()
        if playing { player.active = AudioActive(playing: true, currentTime: 0, duration: 10, playbackRate: 1) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FakeTimeline(player: player, readInRow: readInRow))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let clock = Task { @MainActor in
            var t = 0.0
            while !Task.isCancelled && playing {
                t += 0.05
                player.active?.currentTime = t
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { clock.cancel() }
        for y in stride(from: 395.0, to: 5.0, by: -6) {
            for x in stride(from: 20.0, to: 140.0, by: 6) {
                Self.click(window, at: NSPoint(x: x, y: y))
                try await Task.sleep(for: .milliseconds(20))
                if !player.calls.isEmpty {
                    try await Task.sleep(for: .milliseconds(100))
                    return player.calls + ["at \(Int(x)),\(Int(y))"]
                }
            }
        }
        return player.calls
    }

    @Test func timelinePauseWhilePlaying() async throws {
        let calls = try await clickInTimeline(playing: true)
        #expect(calls.first == "setIsPlaying(false)", "calls: \(calls)")
    }

    @Test func timelineRowReadsThePlayer() async throws {
        let calls = try await clickInTimeline(playing: true, readInRow: true)
        #expect(calls.first == "setIsPlaying(false)", "calls: \(calls)")
    }

    @Test func timelinePlayWhenStill() async throws {
        let calls = try await clickInTimeline(playing: false)
        #expect(calls.first == "playMessage", "calls: \(calls)")
    }

    @Test func playWhenStill() async throws {
        let player = FakePlayer()
        let window = host(player)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        Self.click(window, at: Self.button)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.calls == ["playMessage"], "calls: \(player.calls)")
    }
}

/// The engine in real time (to the output device), playing silence: pause stops the play head.
@MainActor @Suite(.serialized) struct RealtimePauseTests {
    nonisolated static let silence: PCMSource = { start, count in
        let total = 48000 * 20
        let n = max(0, min(count, total - start))
        try? await Task.sleep(for: .milliseconds(30))    // a decode in the media service takes a while
        return PCMChunk(sampleRate: 48000, channels: 1, totalFrames: total, startFrame: start, samples: [Float](repeating: 0, count: n))
    }

    @Test func pauseStopsThePlayHead() async throws {
        let engine = AudioPlaybackEngine()
        try await engine.load(Self.silence)
        await engine.play()
        try await Task.sleep(for: .milliseconds(500))
        let before = engine.currentTime
        #expect(engine.isPlaying && before > 0.2, "playing \(engine.isPlaying) at \(before)")
        engine.pause()
        let paused = engine.currentTime
        try await Task.sleep(for: .milliseconds(500))
        #expect(!engine.isPlaying && !engine.player.isPlaying)
        #expect(abs(engine.currentTime - paused) < 0.01)
    }
}

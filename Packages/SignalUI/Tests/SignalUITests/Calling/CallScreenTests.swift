import SignalI18n
import SwiftUI
import Testing
@testable import SignalUI

/// CallScreen stories (1:1 with Rick Sanchez; we are Morty Smith with the kitten-1 avatar).
/// Storybook paints fake frames into remote video canvases; those rects are excluded.
/// fakeGetGroupCallVideoFrameSource: a solid colour per demux id, 1.3:1.
@MainActor
final class FakeVideoSource: CallVideoFrameSource {
    static let colors: [[UInt8]] = [[0xff, 0, 0], [0xff, 0x99, 0], [0xff, 0xff, 0], [0, 0xff, 0], [0, 0x99, 0xff], [0xff, 0, 0xff], [0x99, 0x33, 0xff]]
    let color: [UInt8]
    init(_ demuxId: UInt32) { color = Self.colors[Int(demuxId) % Self.colors.count] }
    func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        let (w, h) = (130, 100)
        for i in 0..<(w * h) { buffer[i * 4] = color[0]; buffer[i * 4 + 1] = color[1]; buffer[i * 4 + 2] = color[2]; buffer[i * 4 + 3] = 255 }
        return (w, h)
    }
}

@MainActor
@Suite struct CallScreenTests {
    static let rick = CallingConversation(id: "rick", title: "Rick Sanchez", color: "A100")
    static let me = CallingConversation(id: "6146087e-f7ef-457e-9a8d-47df1fdd6b25", title: "Morty Smith", color: "A110",
                                        avatar: fixtureImage("kitten-1-64-64.jpg"), isMe: true, aci: "me")
    static func direct(_ state: DirectCallState, video: Bool = false, audio: Bool = false) -> CallScreenModel {
        CallScreenModel(mode: .direct(state: state, hasRemoteVideo: video, hasRemoteAudio: true, remoteAudioLevel: 0, joinedAt: Date(timeIntervalSince1970: 0),
                                      remoteVideo: nil),
                        conversation: rick, me: me, hasLocalAudio: audio, hasLocalVideo: false)
    }
    static func group(_ ps: [GroupCallRemoteParticipantInfo], ring: Bool = true, connection: GroupCallConnectionState = .connected, hands: [UInt32] = [])
        -> CallScreenModel {
        CallScreenModel(mode: .group(isAdhoc: false, connectionState: connection, joinState: .joined, participants: ps, viewMode: .sidebar, raisedHands: hands,
                                     localDemuxId: 99, outgoingRing: ring, presenting: [], speakerTime: [:], audioLevels: [:], videoSource: { FakeVideoSource($0) }),
                        conversation: rick, me: me, groupMembers: ps.map(\.conversation), hasLocalAudio: false, hasLocalVideo: false)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let now = Date(timeIntervalSince1970: 60)
        let tyler = GroupCallRemoteParticipantInfo(demuxId: 0, conversation: CallingConversation(id: "t", title: "Tyler"), hasRemoteAudio: true)
        let cases: [(String, CallScreenModel, [CGRect])] = [
            ("pre-ring", Self.direct(.prering), []),
            ("direct-ringing", Self.direct(.ringing), []),
            ("group-call-1", Self.group([tyler]), []),
            ("default", Self.direct(.accepted), []),
            ("has-local-audio", Self.direct(.accepted, audio: true), []),
            ("ended", Self.direct(.ended), []),
            ("reconnecting", Self.direct(.reconnecting), []),
            ("group-call-0", Self.group([], ring: false), []),
            ("group-call-outgoing-ringing", Self.group([]), []),
            ("group-call-reconnecting", Self.group([tyler], connection: .reconnecting), []),
            ("group-call-your-hand-raised", Self.group([tyler], hands: [99]), []),
        ]
        for (name, model, ignoring) in cases {
            try Snapshot.assertMatches(CallScreen(model: model, now: now), story: "components-callscreen--\(name)", theme: theme, ignoring: ignoring)
        }
    }

    /// The *WithAvatar stories: getDefaultConversation's random name and kitten, read back.
    static func randomConversation(_ id: String, _ theme: String) -> CallingConversation {
        let d = StoryDOM(id, theme: theme)
        let title = d.nodes.first { $0.cls.contains("CallControls__CallTitle") }?.text ?? ""
        let image = d.nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        return CallingConversation(id: "c", title: title, avatar: image)
    }

    @Test(arguments: ["light", "dark"])
    func moreDirectStories(theme: String) throws {
        let now = Date(timeIntervalSince1970: 60)
        for (name, state) in [("pre-ring-with-avatar", DirectCallState.prering), ("direct-ringing-with-avatar", .ringing),
                              ("reconnecting-with-avatar", .reconnecting)] {
            let id = "components-callscreen--\(name)"
            var model = Self.direct(state)
            model.conversation = Self.randomConversation(id, theme)
            try Snapshot.assertMatches(CallScreen(model: model, now: now), story: id, theme: theme)
        }
        try Snapshot.assertMatches(CallScreen(model: Self.direct(.accepted, video: true), now: now), story: "components-callscreen--has-remote-video", theme: theme)
        var expanded = Self.direct(.accepted)
        expanded.selfViewExpanded = true
        try Snapshot.assertMatches(CallScreen(model: expanded, now: now), story: "components-callscreen--self-view-expanded", theme: theme)
    }

    /// `allRemoteParticipants[0..<n]`: CallScreen.dom.stories.tsx's formulas, with each tile's
    /// random aspect ratio and kitten read back from the capture (tiles are in index order).
    static func storyParticipants(_ id: String, _ theme: String, count: Int,
                                  edit: (Int, inout GroupCallRemoteParticipantInfo) -> Void = { _, _ in }) -> [GroupCallRemoteParticipantInfo] {
        let emojis = ["❤️", "🤔", "✨", "😂", "🦄"]
        let groups = StoryDOM(id, theme: theme).groups(startingWith: "module-ongoing-call__group-call-remote-participant")
        // Tiles are in grid order (presenter / speaker first): match them by "Participant N".
        var tiles: [Int: [StoryDOM.Node]] = [:]
        for (k, g) in groups.enumerated() {
            let name = g.first { $0.text?.hasPrefix("Participant") == true }?.text ?? ""
            let n = Int(name.split(separator: " ").last ?? "").map { $0 - 1 } ?? k
            if tiles[n] == nil { tiles[n] = g }
        }
        return (0..<count).map { i in
            let mediaKeys = (i + 1) % 20 != 0
            let hand = (i - 3) % 10 == 0
            let title = (i - 2) % 4 == 0 ? "Participant \(emojis[((i - 2) / 4) % emojis.count]) \(i + 1)" : "Participant \(i + 1)"
            let tile = tiles[i] ?? []
            let r = tile.first?.rect ?? [0, 0, 1.3, 1]
            let image = (tile.first { $0.cls.contains("module-Avatar__image") } ?? tile.first { $0.cls.contains("module-calling__background--blur") })?
                .fixture.flatMap { fixtureImage($0) }
            // The missing-keys notice names them by `titleNoDefault` (their random profile name).
            let prefix = "Can\u{2019}t receive audio and video from "
            let notice = tile.first { $0.text?.hasPrefix(prefix) == true || $0.text?.hasPrefix("Can't receive audio and video from ") == true }?.text
            var p = GroupCallRemoteParticipantInfo(demuxId: UInt32(i), conversation: CallingConversation(id: "p\(i)", title: title, avatar: image, aci: "aci-\(i)"),
                                                   hasRemoteAudio: mediaKeys ? i % 3 != 0 : false, hasRemoteVideo: mediaKeys ? i % 4 != 0 : false,
                                                   isBlocked: i == 10, mediaKeysReceived: mediaKeys, raisedHandOrder: hand ? (i - 3) / 10 : nil,
                                                   videoAspectRatio: r[2] / r[3], addedTime: 0,
                                                   titleNoDefault: notice.map { String($0.split(separator: " ", maxSplits: 6).last ?? "") })
            edit(i, &p)
            return p
        }
    }

    static func meFrom(_ id: String, _ theme: String) -> CallingConversation {
        var m = me
        m.avatar = StoryDOM(id, theme: theme).nodes.last { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        return m
    }

    @Test(arguments: ["light", "dark"])
    func groupTileStories(theme: String) throws {
        let now = Date(timeIntervalSince1970: 60)
        let blockedId = "components-callscreen--group-call-someone-blocked"
        let blocked = Self.storyParticipants(blockedId, theme, count: 5) { i, p in p.isBlocked = p.isBlocked || i == 1 }
        var m = Self.group(blocked, ring: false, hands: blocked.filter { $0.raisedHandOrder != nil }.map(\.demuxId))
        m.me = Self.meFrom(blockedId, theme)
        try Snapshot.assertMatches(CallScreen(model: m, now: now), story: blockedId, theme: theme)

        let keysId = "components-callscreen--group-call-someone-missing-media-keys"
        let keys = Self.storyParticipants(keysId, theme, count: 5) { i, p in
            p.hasRemoteAudio = false
            p.hasRemoteVideo = false
            p.mediaKeysReceived = i != 1
            p.addedTime = i == 1 ? 0 : nil
        }
        var k = Self.group(keys, ring: false, hands: keys.filter { $0.raisedHandOrder != nil }.map(\.demuxId))
        k.me = Self.meFrom(keysId, theme)
        try Snapshot.assertMatches(CallScreen(model: k, now: now), story: keysId, theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func speakerView(theme: String) throws {
        let id = "components-callscreen--group-call-speaker-view"
        let ps = Self.storyParticipants(id, theme, count: 3)
        var m = Self.group(ps, ring: false)
        if case .group(let adhoc, let c, let j, let p, _, let h, let d, let r, let pr, let st, let al, let vs) = m.mode {
            m.mode = .group(isAdhoc: adhoc, connectionState: c, joinState: j, participants: p, viewMode: .speaker, raisedHands: h, localDemuxId: d,
                            outgoingRing: r, presenting: pr, speakerTime: st, audioLevels: al, videoSource: vs)
        }
        m.me = Self.meFrom(id, theme)
        try Snapshot.assertMatches(CallScreen(model: m, now: Date(timeIntervalSince1970: 60)), story: id, theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func sharingScreen(theme: String) throws {
        for (name, connection) in [("group-call-someone-is-sharing-screen", GroupCallConnectionState.connected),
                                   ("group-call-someone-is-sharing-screen-and-youre-reconnecting", .reconnecting)] {
            let id = "components-callscreen--\(name)"
            let ps = Self.storyParticipants(id, theme, count: 5) { i, p in p.sharingScreen = i == 1 }
            var m = Self.group(ps, ring: false, connection: connection, hands: ps.filter { $0.raisedHandOrder != nil }.map(\.demuxId))
            if case .group(let adhoc, let c, let j, let p, let v, let h, let d, let r, _, let st, let al, let vs) = m.mode {
                m.mode = .group(isAdhoc: adhoc, connectionState: c, joinState: j, participants: p, viewMode: v, raisedHands: h, localDemuxId: d,
                                outgoingRing: r, presenting: [1], speakerTime: st, audioLevels: al, videoSource: vs)
            }
            m.me = Self.meFrom(id, theme)
            try Snapshot.assertMatches(CallScreen(model: m, now: Date(timeIntervalSince1970: 60)), story: id, theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func needsScreenRecordingPermissions(theme: String) throws {
        var m = Self.direct(.accepted)
        m.showNeedsScreenRecordingPermissionsWarning = true
        try Snapshot.assertMatches(CallScreen(model: m, now: Date(timeIntervalSince1970: 60)),
                                   story: "components-callscreen--show-needs-screen-recording-permissions-warning", theme: theme)
    }

    /// GroupCallSuggestLowerHand: our hand was up when the call screen opened; 200ms later
    /// the server suggests lowering it.
    @Test(arguments: ["light", "dark"])
    func suggestLowerHand(theme: String) throws {
        let id = "components-callscreen--group-call-suggest-lower-hand"
        let ps = Self.storyParticipants(id, theme, count: 10)
        var m = Self.group(ps, ring: false, hands: ps.filter { $0.raisedHandOrder != nil }.map(\.demuxId))
        m.me = Self.meFrom(id, theme)
        let toasts = CallingButtonToasts(i18n: Localizer(locale: "en"), now: Date(timeIntervalSince1970: 0))
        let people: (UInt32) -> CallingButtonToasts.Person? = { _ in nil }
        toasts.update(.init(hasLocalAudio: false, raisedHands: [99], suggestLowerHand: false, isHandRaised: true), people: people, localDemuxId: 99,
                      now: Date(timeIntervalSince1970: 0))
        toasts.update(.init(hasLocalAudio: false, raisedHands: [3], suggestLowerHand: true, isHandRaised: true), people: people, localDemuxId: 99,
                      now: Date(timeIntervalSince1970: 0.2))
        #expect(toasts.queue.toasts.map(\.key) == ["SUGGEST_LOWER_HAND_TOAST_KEY"])
        try Snapshot.assertMatches(CallScreen(model: m, now: Date(timeIntervalSince1970: 60), buttonToasts: toasts, initialLocalHandRaised: true),
                                   story: id, theme: theme)
    }

    /// GroupCallReactionsManyInOrder: five reactions at once (the default preferred reaction
    /// emojis), participant 2 being us (LOCAL_DEMUX_ID 1).
    @Test(arguments: ["light", "dark"])
    func reactionsManyInOrder(theme: String) throws {
        let id = "components-callscreen--group-call-reactions-many-in-order"
        let ps = Self.storyParticipants(id, theme, count: 5)
        var m = Self.group(ps, ring: false, hands: ps.filter { $0.raisedHandOrder != nil }.map(\.demuxId))
        if case .group(let adhoc, let c, let j, let p, let v, let h, _, let r, let pr, let st, let al, let vs) = m.mode {
            m.mode = .group(isAdhoc: adhoc, connectionState: c, joinState: j, participants: p, viewMode: v, raisedHands: h, localDemuxId: 1,
                            outgoingRing: r, presenting: pr, speakerTime: st, audioLevels: al, videoSource: vs)
        }
        m.me = Self.meFrom(id, theme)
        let model = CallReactionsModel(i18n: Localizer(locale: "en"))
        let emojis = ["❤️", "👍", "👎", "😂", "😮", "😢"]
        model.update(ps.indices.map { CallReaction(timestamp: 1000, demuxId: UInt32($0), value: emojis[$0]) },
                     people: { id in ps.first { $0.demuxId == id }.map { ($0.conversation.title, $0.conversation.aci) } }, localDemuxId: 1, ourServiceId: nil,
                     now: 1000)
        #expect(model.queue.toasts.count == 5 && model.bursts.isEmpty)
        try Snapshot.assertMatches(CallScreen(model: m, now: Date(timeIntervalSince1970: 60), reactions: model), story: id, theme: theme)
    }

    @Test func reactionBursts() {
        let model = CallReactionsModel(i18n: Localizer(locale: "en"))
        let people: (UInt32) -> (title: String, serviceId: String?)? = { ("P\($0)", "s\($0)") }
        model.update([CallReaction(timestamp: 0, demuxId: 1, value: "👍🏽"), CallReaction(timestamp: 0, demuxId: 2, value: "👍")], people: people,
                     localDemuxId: nil, ourServiceId: nil, now: 0)
        #expect(model.bursts.isEmpty)
        model.update([CallReaction(timestamp: 0, demuxId: 1, value: "👍🏽"), CallReaction(timestamp: 0, demuxId: 2, value: "👍"),
                      CallReaction(timestamp: 100, demuxId: 3, value: "👍")], people: people, localDemuxId: nil, ourServiceId: nil, now: 100)
        #expect(model.bursts.count == 1 && model.bursts[0].values.count == 3 && model.bursts[0].values.contains("👍🏽"))
    }

    /// A 1:1 call with remote video draws the remote frame (Storybook never shows one): the
    /// fake source's solid red fills the centre of the window, contained 1.3:1.
    @Test func directRemoteVideo() throws {
        var m = Self.direct(.accepted, video: true)
        if case .direct(let st, let v, let a, let l, let j, _) = m.mode {
            m.mode = .direct(state: st, hasRemoteVideo: v, hasRemoteAudio: a, remoteAudioLevel: l, joinedAt: j, remoteVideo: FakeVideoSource(0))
        }
        let pixels = try Snapshot.render(CallScreen(model: m, now: Date(timeIntervalSince1970: 60)),
                                         info: ReferenceInfo(id: "direct-remote-video", theme: "dark", width: 800, height: 600, scale: 1, background: [0, 0, 0, 1]))
        let k = (300 * pixels.width + 400) * 4
        #expect(Array(pixels.rgba[k..<(k + 3)]) == [255, 0, 0])
    }
}

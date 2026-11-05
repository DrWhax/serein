// AxoMessage, AxoExpireTimer and AxoOutgoingStatus stories (ts/axo/message/*.dom.stories.tsx).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor enum MessageStory {
    static let bodyShort = "Lorem ipsum dolor sit amet consectetur, adipisicing elit."
    static let bodyMedium = "Lorem ipsum dolor sit amet consectetur, adipisicing elit. Libero "
        + "consequatur iure eaque mollitia! Recusandae sequi ullam reiciendis "
        + "maiores, beatae consequuntur explicabo quos dicta, exercitationem "
        + "magni perferendis autem doloribus odio dolorum."
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// `Chat`: flex flex-col gap-2
    struct Chat<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View { VStack(spacing: 8) { content }.frame(maxWidth: .infinity, alignment: .topLeading) }
    }

    /// `MessageGroup`: flex flex-col
    struct Group<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View { VStack(spacing: 0) { content } }
    }

    @MainActor struct Basic {
        var direction: AxoMessage.Direction = .incoming
        var text = MessageStory.bodyShort
        var timeDisplay = "Now"
        var collapseAbove = false
        var collapseBelow = false
        var view: some View {
            AxoMessage.Root(direction: direction) {
                AxoMessage.Bubble(collapseAbove: collapseAbove, collapseBelow: collapseBelow) {
                    AxoMessage.Text(text: .init(body: text))
                    AxoMessage.Meta { AxoMessage.MetaTimestamp(sentAt: MessageStory.now, timeDisplay) }
                }
            }
        }
    }

    static func basic() -> some View {
        Chat {
            Group {
                Basic(direction: .incoming, text: bodyShort, collapseBelow: true).view
                Basic(direction: .incoming, text: bodyMedium, collapseAbove: true).view
            }
            Group {
                Basic(direction: .outgoing, text: bodyShort, collapseBelow: true).view
                Basic(direction: .outgoing, text: bodyMedium, collapseAbove: true).view
            }
            Basic(direction: .incoming, text: bodyMedium).view
            Basic(direction: .outgoing, text: bodyMedium).view
        }
    }

    static func timestamp() -> some View {
        Chat {
            ForEach(["Now", "1m", "5m", "10m", "30m", "1:11pm", "12:55pm"], id: \.self) { Basic(timeDisplay: $0).view }
        }
    }

    static func partiallySent() -> some View {
        Chat {
            ForEach(AxoMessage.Direction.allCases, id: \.self) { d in
                AxoMessage.Root(direction: d) {
                    AxoMessage.Bubble(collapseAbove: false, collapseBelow: false) {
                        AxoMessage.Text(text: .init(body: bodyShort))
                        AxoMessage.Meta { AxoMessage.MetaAction("Partially sent, click to retry", onClick: {}) }
                    }
                }
            }
        }
    }

    static func outgoingStatus() -> some View {
        Chat {
            ForEach(AxoOutgoingStatus.Status.allCases, id: \.self) { status in
                AxoMessage.Root(direction: .outgoing) {
                    AxoMessage.Bubble(collapseAbove: false, collapseBelow: false) {
                        AxoMessage.Text(text: .init(body: bodyShort))
                        AxoMessage.Meta {
                            AxoMessage.MetaTimestamp(sentAt: now, "Now")
                            AxoMessage.MetaOutgoingStatus(status: status)
                        }
                    }
                }
            }
        }
    }

    /// `div.w-[50ch].resize-x.overflow-auto.border.p-2` (Chromium draws the resize grip in
    /// the bottom-end corner).
    static func wrapping() -> some View {
        Chat {
            ForEach(35...40, id: \.self) { Basic(text: String(repeating: "x", count: $0)).view }
        }
        .padding(8)
        .padding(1)
        .overlay(alignment: .bottomTrailing) { ResizeGrip().frame(width: 8, height: 8).padding(1) }
        .overlay { Rectangle().strokeBorder(AxoColor.labelPrimary, lineWidth: 1) }
        .frame(width: 50 * AxoMessage.ch)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct ResizeGrip: View {
        var body: some View {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: size.width - 7, y: size.height - 0.5))
                p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 7))
                p.move(to: CGPoint(x: size.width - 3.5, y: size.height - 0.5))
                p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 3.5))
                ctx.stroke(p, with: .color(AxoColor.labelSecondary.resolve(in: ctx.environment)), lineWidth: 1)
            }
        }
    }

    /// `AxoOutgoingStatus/AllStatuses`: flex gap-2 type-body-large
    static func allStatuses() -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(AxoOutgoingStatus.Status.allCases, id: \.self) { AxoOutgoingStatus.Root(status: $0, label: $0.defaultLabel) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `AxoExpireTimer/Basic`: 10 s, started now.
    static func expireTimer() -> some View {
        AxoExpireTimer.Root(expireTimer: .init(duration: 10, startedAt: now), now: now)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Suite struct AxoMessageTests {
    nonisolated static let ids = [
        "axo-message-axomessage--basic", "axo-message-axomessage--timestamp", "axo-message-axomessage--partially-sent",
        "axo-message-axomessage--outgoing-status", "axo-message-axomessage--wrapping", "axo-message-axooutgoingstatus--all-statuses",
        "axo-message-axoexpiretimer--basic",
    ]

    static func story(_ id: String) -> AnyView {
        switch id {
        case "axo-message-axomessage--basic": AnyView(MessageStory.basic())
        case "axo-message-axomessage--timestamp": AnyView(MessageStory.timestamp())
        case "axo-message-axomessage--partially-sent": AnyView(MessageStory.partiallySent())
        case "axo-message-axomessage--outgoing-status": AnyView(MessageStory.outgoingStatus())
        case "axo-message-axomessage--wrapping": AnyView(MessageStory.wrapping())
        case "axo-message-axooutgoingstatus--all-statuses": AnyView(MessageStory.allStatuses())
        default: AnyView(MessageStory.expireTimer())
        }
    }

    @Test(arguments: ids, ["light", "dark"])
    func story(id: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(id), story: id, theme: theme)
    }

    @Test func expireTimerSteps() {
        let start = MessageStory.now
        let timer = AxoExpireTimer.ExpireTimer(duration: 12, startedAt: start)
        #expect(AxoExpireTimer.state(timer, now: start).symbol == "timer-countdown-12")
        #expect(AxoExpireTimer.state(timer, now: start.addingTimeInterval(1.5)).symbol == "timer-countdown-11")
        #expect(AxoExpireTimer.state(timer, now: start.addingTimeInterval(11.5)).symbol == "timer-countdown-1")
        #expect(AxoExpireTimer.state(timer, now: start.addingTimeInterval(12)).symbol == "timer-countdown-0")
        #expect(AxoExpireTimer.state(.init(duration: 12, startedAt: nil), now: start).symbol == "timer-countdown-12")
        #expect(AxoExpireTimer.state(timer, now: start.addingTimeInterval(1.5)).updateAt == start.addingTimeInterval(2))
    }
}

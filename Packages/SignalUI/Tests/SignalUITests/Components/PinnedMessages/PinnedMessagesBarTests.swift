// ts/components/conversation/pinned-messages/PinnedMessagesBar.dom.stories.tsx, in the stories'
// Stack (max-w-4xl, gap-4, bg-inverted, p-4). Variants has its Payment row spliced out.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PinnedMessagesBarTests {
    static func stack(_ bars: [([Pin], Int)]) -> some View {
        VStack(spacing: 16) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                PinnedMessagesBar(pins: b.0, current: .constant(b.1), canPinMessages: true)
            }
        }
        .padding(16)
        .background(AxoColor.fillInverted)
        .frame(width: 896)
        .frame(width: 1168, alignment: .leading)
    }

    static func message(_ id: Int, _ edit: (inout PinMessage) -> Void) -> PinMessage {
        var m = PinMessage(id: "message-\(id)")
        edit(&m)
        return m
    }

    static let tina = fixtureImage("tina-rolf-269345-unsplash.jpg")

    static var pin1: Pin { Pin(id: 1, senderTitle: "Jamie", message: message(1) { $0.pollQuestion = "What should we get for lunch?" }) }
    static var pin2: Pin {
        Pin(id: 2, senderTitle: "Tyler", message: message(2) {
            $0.text = ("We found a cute pottery store close to Inokashira Park that we’re going to check out on Saturday. Anyone want to meet at the south exit at Kichijoji station at 1pm? Too early?",
                       [BodyRange(start: 11, length: 4, kind: .formatting(.italic)), BodyRange(start: 39, length: 15, kind: .formatting(.spoiler))])
        })
    }
    static var pin3: Pin {
        Pin(id: 3, senderTitle: "Adrian", message: message(3) {
            $0.text = ("Photo", [])
            $0.attachment = .image(tina)
        })
    }

    static func variant(_ title: String, _ edit: (inout PinMessage) -> Void) -> ([Pin], Int) {
        ([Pin(id: 1, senderTitle: title, message: message(1, edit))], 1)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        try Snapshot.assertMatches(Self.stack([([Self.pin1], 1), ([Self.pin1, Self.pin2], 2), ([Self.pin1, Self.pin2, Self.pin3], 3)]),
                                   story: "components-pinnedmessages-pinnedmessagesbar--default", theme: theme)
        let short = "Lorem, ipsum dolor sit amet"
        let variants: [([Pin], Int)] = [
            Self.variant("Plain text") { $0.text = (short, []) },
            Self.variant("Image attachment with text") { $0.text = (short, []); $0.attachment = .image(Self.tina) },
            Self.variant("Image attachment") { $0.attachment = .image(Self.tina) },
            Self.variant("Video attachment with text") { $0.text = (short, []); $0.attachment = .video(Self.tina) },
            Self.variant("Video attachment") { $0.attachment = .video(Self.tina) },
            Self.variant("Voice message") { $0.attachment = .voiceMessage },
            Self.variant("GIF message") { $0.attachment = .gif },
            Self.variant("File") { $0.attachment = .file("project.zip") },
            Self.variant("Poll") { $0.pollQuestion = "\(short)?" },
            Self.variant("Sticker") { $0.sticker = true; $0.attachment = .image(Self.tina) },
            Self.variant("Contact") { $0.contactName = .some("Tyler"); $0.attachment = .file("") },
            Self.variant("View-Once Media") { $0.viewOnceMedia = true; $0.attachment = .image(Self.tina) },
        ]
        try Snapshot.assertMatches(Self.stack(variants), story: "components-pinnedmessages-pinnedmessagesbar--variants-without-payments", theme: theme)
    }
}

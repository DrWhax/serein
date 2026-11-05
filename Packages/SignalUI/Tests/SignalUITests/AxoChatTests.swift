// AxoChatEvent, AxoChatDateSection and AxoChatUnreadHeader stories (ts/axo/chat/*.dom.stories.tsx).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor enum ChatStory {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let john = AxoChatEvent.InlineAction("John", onClick: {})

    static func basic() -> some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "arrow-clockwise") { "Secure session reset" }
        }
    }

    static func inlineAction() -> some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "leave") {
                john
                " left the group"
            }
        }
    }

    static func timestamp() -> some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "phone") {
                john
                " changed their phone number"
                AxoChatEvent.Timestamp(timestamp: now, "Now")
            }
        }
    }

    static func action() -> some View {
        VStack(spacing: 0) {
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "pin") {
                    john
                    " pinned a message"
                }
                AxoChatEvent.Action("Go to message")
            }
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "message-thread") {
                    john
                    " sent you a message"
                }
                AxoChatEvent.Action("Update Signal")
            }
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "camera") {
                    john
                    " started a video call"
                    AxoChatEvent.Timestamp(timestamp: now, "8m")
                }
                AxoChatEvent.Action("Join call")
            }
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "message-thread") {
                    "You accepted "
                    john
                    "\u{2019}s message request"
                }
                AxoChatEvent.Action("Block or Report...")
            }
        }
    }

    /// The tooltip only opens on hover; at rest the story is the discouraged action.
    static func actionTooltip() -> some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "camera") {
                john
                " started a video call"
                AxoChatEvent.Timestamp(timestamp: now, "8m")
            }
            AxoChatEvent.Action("Join call", discouraged: true)
        }
    }

    static func variants() -> some View {
        VStack(spacing: 0) {
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "camera") { "Incoming video call" }
                AxoChatEvent.Action("Call back")
            }
            AxoChatEvent.Root(variant: .destructive) {
                AxoChatEvent.Body(symbol: "phone") { "Declined voice call" }
                AxoChatEvent.Action("Call back")
            }
        }
    }

    static func longText() -> some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "info") {
                "Lorem, ipsum dolor sit amet consectetur adipisicing elit. Voluptate expedita sunt vero sint ad, amet quas incidunt, "
                    + "explicabo dolorum harum laboriosam non praesentium quibusdam nemo tempora ducimus ipsa facere fugiat"
            }
            AxoChatEvent.Action("Learn More")
        }
    }

    static func rtlTemplate(localeRTL: Bool, contactRTL: Bool) -> some View {
        let contact = AxoChatEvent.InlineAction(contactRTL ? "مُحَمَّد" : "John", onClick: {})
        return AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "phone") {
                if localeRTL {
                    "قام "
                    contact
                    " بتغيير رقم هاتفه"
                } else {
                    contact
                    " changed their phone number"
                }
                AxoChatEvent.Timestamp(timestamp: now, localeRTL ? "الآن" : "Now")
            }
        }
    }

    static func rtl() -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                rtlTemplate(localeRTL: true, contactRTL: true)
                rtlTemplate(localeRTL: true, contactRTL: false)
            }
            .environment(\.layoutDirection, .rightToLeft)
            VStack(spacing: 0) {
                rtlTemplate(localeRTL: false, contactRTL: false)
                rtlTemplate(localeRTL: false, contactRTL: true)
            }
        }
    }

    static func unreadHeader() -> some View { AxoChatUnreadHeader.Root("2 Unread Messages") }

    /// Story `AxoChatDateSection/Basic`: a size-100 bordered wide-scrollbar scroll area.
    struct DateSectionStory: View {
        static let lorem = "Lorem ipsum dolor sit, amet consectetur adipisicing elit. Quasi, cumque. Pariatur rem enim unde nulla animi "
            + "voluptatibus veniam quia repellendus. Quisquam consequuntur quos perferendis saepe animi aliquam ullam rerum nihil!"

        /// `p.curved-2xl.my-1.px-3.py-2.type-body-medium.max-w-4/5` (me-auto / ms-auto)
        struct Message: View {
            let outgoing: Bool
            var body: some View {
                CSSText(DateSectionStory.lorem, type: .bodyMedium, color: outgoing ? .labelPrimaryOncolor : .labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SuperellipseRect.curved(16).fill(outgoing ? AxoColor.surfaceMessageOutgoing : AxoColor.surfaceMessageIncoming))
                    .modifier(FractionOfWidth(fraction: 0.8))
            }
        }

        struct Section: View {
            let date: String
            var body: some View {
                AxoChatDateSection.Root {
                    AxoChatDateSection.Header(date)
                    // my-1 margins collapse: 4 between messages, 4 after the header and at the end.
                    VStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            Message(outgoing: i % 2 == 1).frame(maxWidth: .infinity, alignment: i % 2 == 1 ? .trailing : .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }

        var body: some View {
            AxoScrollArea.Root(scrollbarWidth: .wide) {
                AxoScrollArea.Viewport {
                    AxoScrollArea.Content {
                        // A section's last margin collapses through it: 4 before the next header.
                        VStack(spacing: 0) {
                            ForEach(["Mon, July 6", "Tues, July 7", "Wed, July 8", "Yesterday", "Today"], id: \.self) { Section(date: $0) }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(1)
            .overlay { Rectangle().strokeBorder(AxoColor.labelPrimary, lineWidth: 1) }
            .frame(width: 400, height: 400)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `max-w-4/5` on an auto-width block: 80% of the containing block.
struct FractionOfWidth: ViewModifier {
    let fraction: CGFloat
    struct L: Layout {
        let fraction: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = (proposal.width ?? subviews[0].sizeThatFits(.unspecified).width / fraction) * fraction
            return CGSize(width: w, height: subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
    func body(content: Content) -> some View { L(fraction: fraction) { content } }
}

@MainActor
@Suite struct AxoChatTests {
    nonisolated static let ids = [
        "axo-chat-axochatevent--basic", "axo-chat-axochatevent--inline-action", "axo-chat-axochatevent--timestamp",
        "axo-chat-axochatevent--action", "axo-chat-axochatevent--action-tooltip", "axo-chat-axochatevent--variants",
        "axo-chat-axochatevent--long-text", "axo-chat-axochatevent--rtl", "axo-chat-axochatunreadheader--basic",
        "axo-chat-axochatdatesection--basic",
    ]

    static func story(_ id: String) -> AnyView {
        switch id {
        case "axo-chat-axochatevent--basic": AnyView(ChatStory.basic())
        case "axo-chat-axochatevent--inline-action": AnyView(ChatStory.inlineAction())
        case "axo-chat-axochatevent--timestamp": AnyView(ChatStory.timestamp())
        case "axo-chat-axochatevent--action": AnyView(ChatStory.action())
        case "axo-chat-axochatevent--action-tooltip": AnyView(ChatStory.actionTooltip())
        case "axo-chat-axochatevent--variants": AnyView(ChatStory.variants())
        case "axo-chat-axochatevent--long-text": AnyView(ChatStory.longText())
        case "axo-chat-axochatevent--rtl": AnyView(ChatStory.rtl())
        case "axo-chat-axochatunreadheader--basic": AnyView(ChatStory.unreadHeader())
        default: AnyView(ChatStory.DateSectionStory())
        }
    }

    @Test(arguments: ids, ["light", "dark"])
    func story(id: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(id), story: id, theme: theme)
    }
}

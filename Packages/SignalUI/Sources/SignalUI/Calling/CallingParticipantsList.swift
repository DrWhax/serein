// Port of ts/components/CallingParticipantsList.dom.tsx + CallingParticipantListItem.dom.tsx
// (+ module-calling-participants-list / CallingParticipantsList.scss): "In this call · N
// people" — a 320×440 gray-80 panel over the call, left of centre, listing participants by
// title with their avatar, contacts icon, "Presenting", mute state and the participant menu.

import SignalI18n
import SwiftUI

public struct CallingParticipant: Sendable, Hashable, Identifiable {
    public var conversation: CallingConversation
    public var demuxId: UInt32?
    public var hasRemoteAudio: Bool
    public var presenting: Bool
    public var isInSystemContacts: Bool
    /// No profile name, contact name or number to show (`titleNoDefault` unset).
    public var isUnknownContact: Bool
    public var id: String { "\(conversation.id)-\(demuxId.map(String.init) ?? "")" }

    public init(conversation: CallingConversation, demuxId: UInt32? = nil, hasRemoteAudio: Bool = false, presenting: Bool = false,
                isInSystemContacts: Bool = false, isUnknownContact: Bool = false) {
        self.conversation = conversation
        self.isUnknownContact = isUnknownContact
        self.demuxId = demuxId
        self.hasRemoteAudio = hasRemoteAudio
        self.presenting = presenting
        self.isInSystemContacts = isInSystemContacts
    }
}

public struct CallingParticipantsList: View {
    let participants: [CallingParticipant]
    let ourAci: String?
    let participantMenuDisabled: Bool
    let onClose: () -> Void
    let onParticipantMenu: ((CallingParticipant) -> CallingParticipantMenuActions)?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(participants: [CallingParticipant], ourAci: String? = nil, participantMenuDisabled: Bool = false, onClose: @escaping () -> Void,
                onParticipantMenu: ((CallingParticipant) -> CallingParticipantMenuActions)? = nil) {
        self.participants = participants
        self.ourAci = ourAci
        self.participantMenuDisabled = participantMenuDisabled
        self.onClose = onClose
        self.onParticipantMenu = onParticipantMenu
    }

    /// `sortByTitle`
    var sorted: [CallingParticipant] { Self.sortByTitle(participants) }

    static func sortByTitle(_ participants: [CallingParticipant]) -> [CallingParticipant] {
        participants.enumerated().sorted { a, b in
            let c = a.element.conversation.title.localizedCompare(b.element.conversation.title)
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
        }.map(\.element)
    }

    func row(_ p: CallingParticipant) -> some View {
        CallingParticipantListItem(participant: p, isMe: ourAci != nil && p.conversation.aci == ourAci, participantMenuDisabled: participantMenuDisabled,
                                   onParticipantMenu: onParticipantMenu)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ParticipantsListHeader(title: participants.isEmpty ? i18n("icu:calling__in-this-call--zero")
                                   : i18n("icu:calling__in-this-call", ["people": .number(Double(participants.count))]), onClose: onClose)
            // margin-block 2px per row, collapsing between rows.
            let rows = VStack(spacing: 2) { ForEach(sorted) { row($0) } }.padding(.vertical, 2)
            if staticRendering {
                Color.clear.overlay(alignment: .top) { rows.fixedSize(horizontal: false, vertical: true) }.clipped()     // scroll offset 0
            } else {
                ScrollView(.vertical) { rows }.scrollIndicators(.never)
            }
        }
        .padding(.top, 5).padding(.horizontal, 5)
        .frame(width: 320, height: 440)
        .participantsPanelChrome()
    }
}

/// `module-calling-participants-list__header`: the 13px semibold title and the close button.
struct ParticipantsListHeader: View {
    let title: String
    let onClose: () -> Void
    @State var closeFocused = true
    @Environment(\.i18n) var i18n

    var body: some View {
        HStack(spacing: 0) {
            CSSText(title, style: LegacyType.body2(weight: 600), wrap: .nowrap, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white))
            Spacer(minLength: 0)
            Button(action: onClose) {
                // :focus-visible paints the masked icon ultramarine.
                let tint = closeFocused ? LegacyColor.ultramarine : LegacyColor.gray15
                LegacyIcon.Mask(.x, color: AxoColor(light: tint, dark: tint))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(UndimmedButtonStyle())
            .accessibilityLabel(i18n("icu:close"))
            .onHover { if $0 { closeFocused = false } }
            .padding(.trailing, 4)
        }
        .padding(.vertical, 8).padding(.leading, 10).padding(.trailing, 5)
        .padding(.bottom, 2)
    }
}

extension View {
    /// The gray-80 panel with its 1px gray-62 outline, 10px corners and drop shadow (which a
    /// container with `overflow: hidden` 1px around the panel clips away).
    func participantsPanelChrome(shadow: Bool = true) -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray80)))
            .overlay(RoundedRectangle(cornerRadius: 10).inset(by: -0.5).stroke(Color(rgba: LegacyColor.gray62), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10).inset(by: -1))
            .shadow(color: Color(.sRGB, white: 0, opacity: shadow ? 0.2 : 0), radius: 1.5, x: 0, y: 4)
    }
}

/// `CallingParticipantListItem`: avatar, "You" or the title (+ contacts icon, "Presenting"),
/// the muted-mic slot and the participant menu button.
struct CallingParticipantListItem: View {
    let participant: CallingParticipant
    let isMe: Bool
    let participantMenuDisabled: Bool
    let onParticipantMenu: ((CallingParticipant) -> CallingParticipantMenuActions)?
    @State var menuOpen = false
    @Environment(\.i18n) var i18n

    var body: some View {
        let p = participant
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        let nameStyle = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 20)
        return ParticipantRow(isMe: isMe) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: p.conversation.title, size: 36, conversationType: .direct, color: p.conversation.color,
                           image: p.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: p.conversation.avatar != nil)
                    VStack(alignment: .leading, spacing: 0) {
                        if isMe {
                            CSSText(i18n("icu:you"), style: nameStyle, wrap: .truncate, color: white)
                        } else if p.isInSystemContacts {
                            CSSInlineTail(p.conversation.title + " ", style: nameStyle) {
                                SignalIcon("v3/person/person-circle-compact", size: 14, color: AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray25))
                                    .frame(width: 14, height: 14).padding(.leading, 13 * 0.3)
                            }
                        } else {
                            CSSText(p.conversation.title, style: nameStyle, wrap: .truncate, color: white)
                        }
                        if p.presenting {
                            HStack(spacing: 0) {
                                SignalIcon("v3/share_screen/share_screen-fill-light", size: 16, color: white, mask: true).frame(width: 16, height: 16)
                                    .padding(.horizontal, 8)
                                CSSText(i18n("icu:CallingParticipantListItem__Presenting"), type: .caption, wrap: .nowrap, color: .labelSecondary)
                                    .padding(.leading, -4)
                            }
                            .environment(\.colorScheme, .dark)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ZStack {
                    if !p.hasRemoteAudio {
                        SignalIcon("v3/mic/mic-slash-compact-light", size: 16, color: white, mask: true)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.horizontal, 8)
                if !participantMenuDisabled {
                    // The "more" button opens CallingParticipantMenu (renderCallingParticipantMenu).
                    CallingParticipantMenu(participantTitle: p.conversation.title, actions: onParticipantMenu?(p) ?? CallingParticipantMenuActions(),
                                           isOpen: $menuOpen) {
                        AxoIconButton.Root(label: i18n("icu:CallingParticipantListItem__ContextMenuButton"), tooltip: false, variant: .impliedSecondary,
                                           size: .sm, symbol: "more") { menuOpen.toggle() }
                    }
                    .environment(\.colorScheme, .dark)
                }
            }
        }
    }

}

/// A `__contact` row: 8px vertical / 10px start / 2px end padding, gray-62 on hover (not for us).
struct ParticipantRow<Content: View>: View {
    let isMe: Bool
    let content: Content
    @State var hovered = false
    init(isMe: Bool, @ViewBuilder content: () -> Content) {
        self.isMe = isMe
        self.content = content()
    }
    var body: some View {
        content
            .padding(.vertical, 8).padding(.leading, 10).padding(.trailing, 2)
            .background { if hovered && !isMe { RoundedRectangle(cornerRadius: 6).fill(Color(rgba: LegacyColor.gray62)) } }
            .onHover { hovered = $0 }
    }
}

/// `CallingParticipantsList__modal`: the panel in the call, centred in the space left of a
/// 480px reserve (15px start padding), 20px into a 462px band 80px above the bottom.
public struct CallingParticipantsListOverlay: View {
    let list: CallingParticipantsList
    public init(_ list: CallingParticipantsList) { self.list = list }
    public var body: some View {
        GeometryReader { g in
            let free = max(0, g.size.width - 15 - 320 - 480)
            list
                .padding(.leading, 15 + free / 2)
                .padding(.top, max(0, g.size.height - 80 - 462) + 21)     // the band sits on its 80px bottom margin
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}

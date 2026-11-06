// Port of ts/components/CallingAdhocCallInfo.dom.tsx (+ CallingAdhocCallInfo.scss): the call
// link "In this call" panel — participants by title, people we know nothing about folded into
// one "+N more" row with stacked avatars and an info button, then "Copy call link" and
// "Share call link via Signal".

import SignalI18n
import SwiftUI

public struct CallingAdhocCallInfo: View {
    let participants: [CallingParticipant]
    let ourAci: String?
    let isUnknownContactDiscrete: Bool
    let participantMenuDisabled: Bool
    let onClose: () -> Void
    let onCopyCallLink: () -> Void
    let onShareCallLinkViaSignal: () -> Void
    let onParticipantMenu: ((CallingParticipant) -> CallingParticipantMenuActions)?
    @State var unknownContactDialog = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(participants: [CallingParticipant], ourAci: String?, isUnknownContactDiscrete: Bool = false, participantMenuDisabled: Bool = false,
                onClose: @escaping () -> Void, onCopyCallLink: @escaping () -> Void, onShareCallLinkViaSignal: @escaping () -> Void,
                onParticipantMenu: ((CallingParticipant) -> CallingParticipantMenuActions)? = nil) {
        self.participants = participants
        self.ourAci = ourAci
        self.isUnknownContactDiscrete = isUnknownContactDiscrete
        self.participantMenuDisabled = participantMenuDisabled
        self.onClose = onClose
        self.onCopyCallLink = onCopyCallLink
        self.onShareCallLinkViaSignal = onShareCallLinkViaSignal
        self.onParticipantMenu = onParticipantMenu
    }

    /// (shown by title, folded into the unknown-contacts row)
    var partitioned: (visible: [CallingParticipant], unknown: [CallingParticipant]) {
        let visible = participants.filter { isUnknownContactDiscrete || !$0.isUnknownContact }
        let unknown = participants.filter { !isUnknownContactDiscrete && $0.isUnknownContact }
        return (CallingParticipantsList.sortByTitle(visible), unknown)
    }

    /// Unknown contacts get a colour from their service id (last 4 hex digits % 12), not their title.
    static func unknownColor(_ aci: String?) -> String {
        let colors = AxoTokensTables.avatarColors
        guard let aci, let n = Int(aci.suffix(4), radix: 16) else { return colors[0].name }
        return colors[n % colors.count].name
    }

    func unknownContacts(_ unknown: [CallingParticipant], inAddition: Bool) -> some View {
        let shown = Array(unknown.prefix(3))    // MAX_UNKNOWN_AVATARS_COUNT
        let size: CGFloat = shown.count == 1 ? 36 : shown.count == 2 ? 30 : 28
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        return ParticipantRow(isMe: false) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: -24) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                            Avatar(strings: AvatarStrings(i18n: i18n), title: p.conversation.title, size: size, conversationType: .direct,
                                   color: Self.unknownColor(p.conversation.aci), image: p.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) },
                                   hasAvatar: p.conversation.avatar != nil)
                                .background(Circle().fill(Color(rgba: LegacyColor.gray80)).padding(-2))     // outline: 2px gray-80
                        }
                    }
                    .frame(height: 36)
                    CSSText(i18n(inAddition ? "icu:CallingAdhocCallInfo__UnknownContactLabel--in-addition" : "icu:CallingAdhocCallInfo__UnknownContactLabel",
                                 ["count": .number(Double(unknown.count))]),
                            style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 20), wrap: .truncate, color: white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { unknownContactDialog = true } label: {
                    SignalIcon("v3/info/info", size: 16, color: white, mask: true).frame(width: 16, height: 16)
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel("icu:CallingAdhocCallInfo__UnknownContactInfoButton")     // (sic: upstream passes the key)
                .padding(.horizontal, 8)
            }
        }
    }

    func menuItem(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        ParticipantRow(isMe: false) {
            Button(action: action) {
                HStack(spacing: 8) {
                    SignalIcon(icon, size: 18, color: AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15), mask: true)
                        .frame(width: 18, height: 18)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(rgba: LegacyColor.gray65)))
                    CSSText(label, style: LegacyType.body2(weight: 400), wrap: .nowrap, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(UndimmedButtonStyle())
        }
    }

    @ViewBuilder var panel: some View {
        let (visible, unknown) = partitioned
        VStack(spacing: 0) {
            ParticipantsListHeader(title: participants.isEmpty ? i18n("icu:calling__in-this-call--zero")
                                   : i18n("icu:calling__in-this-call", ["people": .number(Double(participants.count))]), onClose: onClose)
            let rows = VStack(spacing: 2) {
                ForEach(visible) { p in
                    CallingParticipantListItem(participant: p, isMe: ourAci != nil && p.conversation.aci == ourAci,
                                               participantMenuDisabled: participantMenuDisabled, onParticipantMenu: onParticipantMenu)
                }
                if !unknown.isEmpty { unknownContacts(unknown, inAddition: !visible.isEmpty) }
            }
            .padding(.vertical, participants.isEmpty ? 0 : 2)     // the rows' 2px margins
            if staticRendering {
                rows.fixedSize(horizontal: false, vertical: true).frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView(.vertical) { rows }.scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
            }
            Rectangle().fill(Color(rgba: LegacyColor.gray65)).frame(height: 2).padding(.horizontal, 10).padding(.vertical, 16)
            VStack(spacing: 0) {
                menuItem("v3/copy/copy", i18n("icu:CallingAdhocCallInfo__CopyLink"), action: onCopyCallLink)
                menuItem("v3/forward/forward", i18n("icu:CallingAdhocCallInfo__ShareViaSignal")) {
                    onClose()
                    onShareCallLinkViaSignal()
                }
            }
        }
        .padding(.top, 5).padding(.horizontal, 5).padding(.bottom, 16)
        .frame(width: 320)
        .participantsPanelChrome()
    }

    /// `CallingAdhocCallInfo__modal`: like the participants list, centred in the space left of
    /// a 480px reserve (15px start padding), its bottom 81px above the call's, at most
    /// 100vh − 102px tall; the unknown-contact info dialog above it.
    public var body: some View {
        ZStack {
            GeometryReader { g in
                let free = max(0, g.size.width - 15 - 320 - 480)
                CappedHeight(max: max(0, g.size.height - 80 - 22)) { panel }
                    .padding(.leading, 15 + free / 2)
                    .padding(.bottom, 81)
                    .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
            }
            if unknownContactDialog {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:CallingAdhocCallInfo__UnknownContactInfoDialogBody")) {
                        AxoConfirmDialog.Ok(i18n("icu:ok")) { unknownContactDialog = false }
                    }
                }
            }
        }
    }
}

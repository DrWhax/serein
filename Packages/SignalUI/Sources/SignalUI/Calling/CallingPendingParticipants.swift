// Port of ts/components/CallingPendingParticipants.dom.tsx (+ CallingPendingParticipants.scss):
// call-link admins see people asking to join. Compact: the first request as a 364px card
// ("Would like to join…", deny / approve) with "+N requests" below it when there are more;
// expanded: a 420px "N requests to join the call" list with per-row and "Deny all" /
// "Approve all" actions, each batch confirmed first.

import SignalI18n
import SwiftUI

public struct CallingPendingParticipants: View {
    public enum BatchAction: Sendable, Hashable { case approve, deny }
    enum Confirm { case none, approveAll, denyAll }

    let participants: [CallingParticipant]
    let approveUser: (CallingParticipant) -> Void
    let denyUser: (CallingParticipant) -> Void
    let batchUserAction: (BatchAction, [String]) -> Void
    let showParticipant: (CallingParticipant) -> Void
    @State var isExpanded: Bool
    @State var confirm = Confirm.none
    /// The ACIs in the list when a batch dialog opened: later requests are not included.
    @State var staged: [String] = []
    @State var opacity: Double = 0
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    public init(participants: [CallingParticipant], defaultIsExpanded: Bool = false, approveUser: @escaping (CallingParticipant) -> Void,
                denyUser: @escaping (CallingParticipant) -> Void, batchUserAction: @escaping (BatchAction, [String]) -> Void,
                showParticipant: @escaping (CallingParticipant) -> Void) {
        self.participants = participants
        self.approveUser = approveUser
        self.denyUser = denyUser
        self.batchUserAction = batchUserAction
        self.showParticipant = showParticipant
        _isExpanded = State(initialValue: defaultIsExpanded)
    }

    static let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)

    /// `CallingPendingParticipants__PendingActionButton`: a red ✕ / green ✓ circle, 36px with a
    /// 20px icon in the compact card, 28px with 16px in the list. Requests without an ACI
    /// get no buttons.
    @ViewBuilder
    func approvalButtons(_ p: CallingParticipant, compact: Bool, enabled: Bool = true) -> some View {
        if p.conversation.aci != nil {
            let size: CGFloat = compact ? 36 : 28
            let icon: CGFloat = compact ? 20 : 16
            HStack(spacing: compact ? 20 : 16) {
                circle(LegacyButton.Variant.destructive, "v3/x/x-bold", size: size, icon: icon, label: i18n("icu:CallingPendingParticipants__DenyUser")) {
                    if enabled { denyUser(p) }
                }
                circle(LegacyButton.Variant.calling, "v3/check/check-bold", size: size, icon: icon,
                       label: i18n("icu:CallingPendingParticipants__ApproveUser")) {
                    if enabled { approveUser(p) }
                }
            }
            .padding(.leading, compact ? 0 : 8)
            .padding(.trailing, compact ? 0 : 8)
        }
    }

    func circle(_ variant: LegacyButton.Variant, _ symbol: String, size: CGFloat, icon: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SignalIcon(symbol, size: icon, color: Self.white, mask: true)
                .frame(width: icon, height: icon)
                .frame(width: size, height: size)
                .background(Circle().fill(variant.style.background))
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Expanded

    var expanded: some View {
        let nameStyle = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 20)
        return VStack(spacing: 0) {
            ParticipantsListHeader(title: i18n("icu:CallingPendingParticipants__RequestsToJoin", ["count": .number(Double(participants.count))]),
                                   onClose: { isExpanded = false })
            let rows = VStack(spacing: 2) {
                ForEach(Array(participants.enumerated()), id: \.offset) { _, p in
                    ParticipantRow(isMe: false) {
                        HStack(spacing: 0) {
                            Button { showParticipant(p) } label: {
                                HStack(spacing: 8) {
                                    Avatar(strings: AvatarStrings(i18n: i18n), title: p.conversation.title, size: 36, conversationType: .direct,
                                           color: p.conversation.color, image: p.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) },
                                           hasAvatar: p.conversation.avatar != nil)
                                    if p.isInSystemContacts {
                                        CSSInlineTail(p.conversation.title + " ", style: nameStyle) { Self.contactIcon }
                                    } else {
                                        CSSText(p.conversation.title, style: nameStyle, wrap: .truncate, color: Self.white)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(UndimmedButtonStyle())
                            approvalButtons(p, compact: false)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            if staticRendering {
                rows.fixedSize(horizontal: false, vertical: true).frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView(.vertical) { rows }.scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
            }
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                LegacyButton(i18n("icu:CallingPendingParticipants__DenyAll"), variant: .destructive) { stage(.denyAll) }
                LegacyButton(i18n("icu:CallingPendingParticipants__ApproveAll"), variant: .calling) { stage(.approveAll) }
            }
            .padding(.trailing, 10)
            .padding(.vertical, 15)
        }
        .padding(.top, 5).padding(.horizontal, 5).padding(.bottom, 2)
        .frame(width: 420)
        .background(Color(rgba: LegacyColor.gray80))
        .participantsPanelChrome()
    }

    static var contactIcon: some View {
        SignalIcon("v3/person/person-circle-compact", size: 14, color: AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray25))
            .frame(width: 14, height: 14).padding(.leading, 13 * 0.3)
    }

    func stage(_ c: Confirm) {
        staged = participants.compactMap(\.conversation.aci)
        confirm = c
    }

    // MARK: Compact

    func compact(_ p: CallingParticipant) -> some View {
        let isExpandable = participants.count > 1
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { showParticipant(p) } label: {
                    HStack(spacing: 8) {
                        Avatar(strings: AvatarStrings(i18n: i18n), title: p.conversation.title, size: 48, conversationType: .direct, color: p.conversation.color,
                               image: p.conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: p.conversation.avatar != nil)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 0) {
                                CSSText(p.conversation.title, style: LegacyType.body1(weight: 600), wrap: .truncate,
                                        color: AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15))
                                if p.isInSystemContacts { Self.contactIcon.padding(.top, 3) }
                                // position: relative; top: 3px on an inline-block sitting on the baseline.
                                SignalIcon("v3/chevron/chevron-right-bold", size: 14, color: AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray05),
                                           mask: true)
                                    .frame(width: 14, height: 14).padding(.top, 4)
                            }
                            CSSText(i18n("icu:CallingPendingParticipants__WouldLikeToJoin"), style: LegacyType.body2(weight: 400), wrap: .nowrap,
                                    color: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(UndimmedButtonStyle())
                approvalButtons(p, compact: true, enabled: !participants.isEmpty)
            }
            .padding(12)
            if isExpandable {
                Button { isExpanded = true } label: {
                    CSSText(i18n("icu:CallingPendingParticipants__AdditionalRequests", ["count": .number(Double(participants.count - 1))]),
                            style: LegacyType.body2(weight: 600), wrap: .nowrap, color: AxoColor(light: LegacyColor.whiteAlpha90, dark: LegacyColor.whiteAlpha90))
                        .padding(.vertical, 5).padding(.horizontal, 15)
                        .background(Capsule().fill(Color(rgba: LegacyColor.gray65)))
                }
                .buttonStyle(UndimmedButtonStyle())
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color(rgba: LegacyColor.blackAlpha24))
            }
        }
        .frame(width: 364)
        .background(Color(rgba: isExpandable ? LegacyColor.gray78 : LegacyColor.gray80))
        .participantsPanelChrome()
    }

    public var body: some View {
        switch confirm {
        case .approveAll:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: i18n("icu:CallingPendingParticipants__ConfirmDialogTitle--ApproveAll", ["count": .number(Double(staged.count))]),
                                      description: i18n("icu:CallingPendingParticipants__ConfirmDialogBody--ApproveAll", ["count": .number(Double(staged.count))])) {
                    AxoConfirmDialog.Cancel(i18n("icu:cancel")) { hideConfirm() }
                    AxoConfirmDialog.Action(i18n("icu:CallingPendingParticipants__ApproveAll"), variant: .strongPrimary) {
                        batchUserAction(.approve, staged)
                        hideConfirm()
                    }
                }
            }
        case .denyAll:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: i18n("icu:CallingPendingParticipants__ConfirmDialogTitle--DenyAll", ["count": .number(Double(staged.count))]),
                                      description: i18n("icu:CallingPendingParticipants__ConfirmDialogBody--DenyAll", ["count": .number(Double(staged.count))])) {
                    AxoConfirmDialog.Cancel(i18n("icu:cancel")) { hideConfirm() }
                    AxoConfirmDialog.Action(i18n("icu:CallingPendingParticipants__DenyAll"), variant: .strongDestructive) {
                        batchUserAction(.deny, staged)
                        hideConfirm()
                    }
                }
            }
        case .none:
            if isExpanded {
                expanded
            } else if let first = participants.first {
                compact(first)
                    .opacity(staticRendering || reduceMotion ? 1 : opacity)
                    .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.61)) { opacity = 1 } }
                    .transition(.opacity)
            }
        }
    }

    func hideConfirm() {
        confirm = .none
        staged = []
    }
}

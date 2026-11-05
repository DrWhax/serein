// The other bars that replace the composer: MandatoryProfileSharingActions (share your profile
// to keep chatting), GroupV1DisabledActions (upgrade an old group) and
// GroupV2PendingApprovalActions (cancel a pending join request).

import SignalI18n
import SwiftUI

/// MandatoryProfileSharingActions (ts/components/conversation/MandatoryProfileSharingActions.dom.tsx)
public struct MandatoryProfileSharingActions: View {
    let model: MessageRequestModel
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    @Environment(\.openURL) var openURL

    public init(model: MessageRequestModel) { self.model = model }

    func open(_ state: MessageRequestState) {
        let id = "profile-sharing-\(model.conversationId)"
        guard let modals else { return }
        modals.present(id: id) {
            MessageRequestActionsConfirmation(model: model, state: state) { next in
                if next == .default { modals.dismiss(id: id) } else { open(next) }
            }
        }
    }

    var text: [CSSTextRun] {
        // learnMoreLink: an unstyled <a> without underline (the UA link colour).
        let link = I18nTagStyle(color: Linkify.uaLinkColor, action: "learn-more")
        if model.conversationType == .direct {
            var name = CSSTextRun(model.conversationName, fontName: AxoFonts.interName(weight: 600))
            name.emojify = true
            return CSSTextRun.runs(i18n.richText("icu:MessageRequests--profile-sharing--direct--link", ["firstName": .element("firstName")]),
                                   tags: ["learnMoreLink": link], elements: ["firstName": name])
        }
        return CSSTextRun.runs(i18n.richText("icu:MessageRequests--profile-sharing--group--link"), tags: ["learnMoreLink": link])
    }

    public var body: some View {
        VStack(spacing: 0) {
            CSSText(runs: text, style: CSSTextStyle(AxoType.bodyMedium), alignment: .center, color: .labelSecondary, onTap: { _ in
                if let url = URL(string: "https://support.signal.org/hc/articles/360007459591") { openURL(url) }
            })
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
            AxoButton.Group {
                Group {
                    AxoButton.Root(i18n("icu:MessageRequests--block"), variant: .subtleDestructive, size: .md) { open(.blocking) }
                    AxoButton.Root(i18n("icu:MessageRequests--delete"), variant: .subtleDestructive, size: .md) { open(.deleting) }
                    AxoButton.Root(i18n("icu:MessageRequests--continue"), variant: .subtleSecondary, size: .md, action: model.acceptConversation)
                }
                .environment(\.axoButtonMinWidthFit, true)
            }
            .padding(4)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

/// The legacy bar layout shared by the two group bars: max 650px centred, white / gray-95,
/// a body-2 gray-60 / gray-25 message 12px above a centred body-1-bold button (radius 4,
/// padding 8px 30px).
struct LegacyActionBar<Button: View>: View {
    let message: [CSSTextRun]
    let onLink: () -> Void
    @ViewBuilder let button: Button

    var body: some View {
        VStack(spacing: 0) {
            CSSText(runs: message, style: LegacyType.body2(), alignment: .center, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25),
                    onTap: { _ in onLink() })
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            button
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: 650)
        .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95))
        .frame(maxWidth: .infinity)
    }
}

/// A `button-reset` + body-1-bold button with the given colours (legacy button mixins).
struct LegacyBarButton: View {
    let label: String
    let text: AxoColor
    let background: AxoColor
    let border: AxoColor?
    let action: () -> Void
    var body: some View {
        SwiftUI.Button(action: action) {
            CSSText(label, style: LegacyType.body1(weight: 600), wrap: .nowrap, color: text)
                .padding(.vertical, 8).padding(.horizontal, 30)
                .background(RoundedRectangle(cornerRadius: 4).fill(background))
                .overlay { if let border { RoundedRectangle(cornerRadius: 4).strokeBorder(border, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
    }
}

/// GroupV1DisabledActions (ts/components/conversation/GroupV1DisabledActions.dom.tsx)
public struct GroupV1DisabledActions: View {
    let showGV2MigrationDialog: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL
    public init(showGV2MigrationDialog: @escaping () -> Void) { self.showGV2MigrationDialog = showGV2MigrationDialog }

    public var body: some View {
        LegacyActionBar(message: CSSTextRun.runs(i18n.richText("icu:GroupV1--Migration--disabled--link"),
                                                 tags: ["learnMoreLink": I18nTagStyle(color: Linkify.uaLinkColor, action: "learn-more")]),
                        onLink: { if let url = URL(string: "https://support.signal.org/hc/articles/360007319331") { openURL(url) } }) {
            // button-primary: ultramarine, white text, 1px white / gray-95 border
            LegacyBarButton(label: i18n("icu:MessageRequests--continue"), text: AxoColor(light: LegacyColor.white, dark: LegacyColor.whiteAlpha90),
                            background: AxoColor(LegacyColor.ultramarine), border: AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95),
                            action: showGV2MigrationDialog)
        }
    }
}

/// GroupV2PendingApprovalActions (ts/components/conversation/GroupV2PendingApprovalActions.dom.tsx)
public struct GroupV2PendingApprovalActions: View {
    let cancelJoinRequest: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    public init(cancelJoinRequest: @escaping () -> Void) { self.cancelJoinRequest = cancelJoinRequest }

    public var body: some View {
        LegacyActionBar(message: [CSSTextRun(i18n("icu:GroupV2--join--requested"))], onLink: {}) {
            // button-secondary, light overridden to gray-60 on gray-05
            LegacyBarButton(label: i18n("icu:GroupV2--join--cancel-request-to-join"), text: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05),
                            background: AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray65), border: nil) { confirm() }
        }
    }

    func confirm() {
        guard let modals else { return }
        let id = "cancel-join-request"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:GroupV2--join--cancel-request-to-join--confirmation")) {
                AxoConfirmDialog.Cancel(i18n("icu:GroupV2--join--cancel-request-to-join--no")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:GroupV2--join--cancel-request-to-join--yes"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    cancelJoinRequest()
                }
            }
        }
    }
}

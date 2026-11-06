// Port of ts/components/CallLinkDetails.dom.tsx (+ CallLinkDetails.scss): the Calls tab's
// details for a call link — its avatar, name and signal.link URL with "Join" / "Return to
// call", the call history, then (admins) rename and "Require admin approval", copy/share,
// and (admins) "Delete link" with its confirmation.

import SignalI18n
import SwiftUI

/// `CallLinkType` (the parts the Calls tab shows).
public struct CallLinkInfo: Sendable, Hashable {
    public var name: String
    /// The root key in Signal's consonant base-16 form (`bpmc-mrgn-…`).
    public var rootKey: String
    public var isAdmin: Bool
    public var requiresAdminApproval: Bool
    public var revoked: Bool

    public init(name: String, rootKey: String, isAdmin: Bool, requiresAdminApproval: Bool = false, revoked: Bool = false) {
        self.name = name
        self.rootKey = rootKey
        self.isAdmin = isAdmin
        self.requiresAdminApproval = requiresAdminApproval
        self.revoked = revoked
    }

    /// `linkCallRoute.toWebUrl({ key })`
    public var webURL: String { "https://signal.link/call/#key=\(rootKey)" }
    /// `toUrlWithoutProtocol`
    public var webURLWithoutProtocol: String { "signal.link/call/#key=\(rootKey)" }
}

public struct CallLinkDetails: View {
    let callLink: CallLinkInfo?
    let callHistoryGroup: CallHistoryGroup
    let isAnybodyInCall: Bool
    let isCallActiveOnServer: Bool
    let isInCall: Bool
    let isInAnotherCall: Bool
    let onDeleteCallLink: () -> Void
    let onOpenCallLinkAddNameModal: () -> Void
    let onStartCallLinkLobby: () -> Void
    let onShareCallLinkViaSignal: () -> Void
    let onCopyCallLink: (String) -> Void
    let onUpdateCallLinkRestrictions: (Bool) -> Void
    @State var isDeleteModalOpen = false
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var colorScheme

    public init(callLink: CallLinkInfo?, callHistoryGroup: CallHistoryGroup, isAnybodyInCall: Bool = false, isCallActiveOnServer: Bool = false,
                isInCall: Bool = false, isInAnotherCall: Bool = false, onDeleteCallLink: @escaping () -> Void = {},
                onOpenCallLinkAddNameModal: @escaping () -> Void = {}, onStartCallLinkLobby: @escaping () -> Void = {},
                onShareCallLinkViaSignal: @escaping () -> Void = {}, onCopyCallLink: @escaping (String) -> Void = { _ in },
                onUpdateCallLinkRestrictions: @escaping (Bool) -> Void = { _ in }) {
        self.callLink = callLink
        self.callHistoryGroup = callHistoryGroup
        self.isAnybodyInCall = isAnybodyInCall
        self.isCallActiveOnServer = isCallActiveOnServer
        self.isInCall = isInCall
        self.isInAnotherCall = isInAnotherCall
        self.onDeleteCallLink = onDeleteCallLink
        self.onOpenCallLinkAddNameModal = onOpenCallLinkAddNameModal
        self.onStartCallLinkLobby = onStartCallLinkLobby
        self.onShareCallLinkViaSignal = onShareCallLinkViaSignal
        self.onCopyCallLink = onCopyCallLink
        self.onUpdateCallLinkRestrictions = onUpdateCallLinkRestrictions
    }

    func header(title: String, color: String?, url: String?, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 16) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: title, size: 64, conversationType: .callLink, color: color ?? "A200")
            VStack(alignment: .leading, spacing: 0) {
                CSSText(title, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 18, lineHeight: 25), color: .labelPrimary)
                if let url {
                    CSSText(url, style: LegacyType.body1(weight: 400), color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.bottom, 24)
    }

    func list(@ViewBuilder _ items: () -> some View) -> some View {
        AxoList.Root { AxoList.Body { AxoItem.Group { items() } } }
    }

    public var body: some View {
        if let callLink {
            details(callLink)
        } else {
            // renderMissingCallLink: a plain block, no container.
            VStack(alignment: .leading, spacing: 0) {
                header(title: i18n("icu:calling__call-link-default-title"), color: nil, url: nil) { EmptyView() }
                CallHistoryGroupPanelSection(callHistoryGroup: callHistoryGroup)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    func details(_ link: CallLinkInfo) -> some View {
        let title = link.name.isEmpty ? i18n("icu:calling__call-link-default-title") : link.name
        return AxoContainer.Root {
            header(title: title, color: callLinkColor(link.rootKey), url: link.webURLWithoutProtocol) {
                AxoButton.Root(isInCall ? i18n("icu:CallsNewCallButton--return") : i18n("icu:CallLinkDetails__Join"),
                               variant: isAnybodyInCall || isInCall ? .strongAffirmative : .subtleAffirmative, size: .md, symbol: "videocamera-fill",
                               discouraged: isInAnotherCall, action: onStartCallLinkLobby)
                    .help(isInAnotherCall ? i18n("icu:calling__in-another-call-tooltip") : "")
            }
            AxoList.Group {
                CallHistoryGroupPanelSection(callHistoryGroup: callHistoryGroup)
                if link.isAdmin {
                    list {
                        AxoClickableItem.Root(symbol: "pencil",
                                              label: i18n(link.name.isEmpty ? "icu:CallLinkDetails__AddCallNameLabel" : "icu:CallLinkDetails__EditCallNameLabel"),
                                              arrow: .next, onClick: onOpenCallLinkAddNameModal)
                        AxoSwitchItem.Root(symbol: "person-check", label: i18n("icu:CallLinkDetails__ApproveAllMembersLabel"), disabled: isCallActiveOnServer,
                                           checked: Binding(get: { link.requiresAdminApproval }, set: { onUpdateCallLinkRestrictions($0) }),
                                           tooltip: isCallActiveOnServer ? i18n("icu:CallLinkDetails__SettingTooltip--disabled-for-active-call") : nil)
                    }
                }
                list {
                    AxoClickableItem.Root(symbol: "copy", label: i18n("icu:CallLinkDetails__CopyLink"), onClick: { onCopyCallLink(link.webURL) })
                    AxoClickableItem.Root(symbol: "share", label: i18n("icu:CallLinkDetails__ShareLinkViaSignal"), onClick: onShareCallLinkViaSignal)
                }
                if link.isAdmin {
                    list {
                        AxoClickableItem.Root(variant: .destructive, symbol: "trash", label: i18n("icu:CallLinkDetails__DeleteLink"), disabled: isCallActiveOnServer,
                                              tooltip: isCallActiveOnServer ? i18n("icu:CallLinkDetails__DeleteLinkTooltip--disabled-for-active-call") : nil,
                                              onClick: { isDeleteModalOpen = true })
                    }
                }
            }
        }
        .overlay {
            if isDeleteModalOpen {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("icu:CallLinkDetails__DeleteLinkModal__Title"), description: i18n("icu:CallLinkDetails__DeleteLinkModal__Body")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { isDeleteModalOpen = false }
                        AxoConfirmDialog.Action(i18n("icu:CallLinkDetails__DeleteLinkModal__Delete"), variant: .strongDestructive) {
                            isDeleteModalOpen = false
                            onDeleteCallLink()
                        }
                    }
                }
            }
        }
    }
}

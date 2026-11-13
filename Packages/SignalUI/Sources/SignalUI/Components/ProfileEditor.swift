// Port of ts/components/ProfileEditor.dom.tsx: the Profile page — the 80px avatar with
// "Edit photo", name and about rows, and the username rows (copy / delete menu, deleting and
// corrupted states, username link) with their confirmation dialogs.
//
// The avatar page is AvatarEditor. The name, about, username and username-link pages are
// supplied by the caller (`renderSubpage`); their editors are ported separately.

import SignalI18n
import SwiftUI

/// `ProfileEditorPage`
public enum ProfileEditorPage: Sendable, Hashable { case none, betterAvatar, bio, profileName, username, usernameLink }

/// `UsernameEditState`
public enum UsernameEditState: Sendable, Hashable { case editing, confirmingDelete, deleting }

public struct ProfileEditor: View {
    public struct Actions {
        public var openUsernameReservationModal: () -> Void = {}
        public var deleteUsername: () -> Void = {}
        /// Copies the username and shows `ToastType.CopiedUsername`.
        public var copyUsername: (String) -> Void = { _ in }
        public var markCompletedUsernameLinkOnboarding: () -> Void = {}
        public var avatarEditor = AvatarEditor.Callbacks()
        public init() {}
    }

    let aboutEmoji: String?
    let aboutText: String?
    let color: String?
    let avatar: RGBAImage?
    let firstName: String
    let familyName: String?
    let username: String?
    let usernameCorrupted: Bool
    let usernameLink: String?
    let usernameLinkCorrupted: Bool
    let hasCompletedUsernameLinkOnboarding: Bool
    let userAvatarData: [AvatarData]
    @Binding var editState: ProfileEditorPage
    @Binding var usernameEditState: UsernameEditState
    let actions: Actions
    let renderSubpage: (ProfileEditorPage, @escaping () -> Void) -> AnyView
    @State private var isResettingUsername = false
    @State private var isResettingUsernameLink = false
    @State private var usernameMenuOpen = false
    @Environment(\.i18n) var i18n

    public init(aboutEmoji: String? = nil, aboutText: String? = nil, color: String? = nil, avatar: RGBAImage? = nil, firstName: String,
                familyName: String? = nil, username: String? = nil, usernameCorrupted: Bool = false, usernameLink: String? = nil,
                usernameLinkCorrupted: Bool = false, hasCompletedUsernameLinkOnboarding: Bool = false, userAvatarData: [AvatarData] = [],
                editState: Binding<ProfileEditorPage>, usernameEditState: Binding<UsernameEditState>, actions: Actions = Actions(),
                renderSubpage: @escaping (ProfileEditorPage, @escaping () -> Void) -> AnyView = { _, _ in AnyView(EmptyView()) }) {
        self.aboutEmoji = aboutEmoji
        self.aboutText = aboutText
        self.color = color
        self.avatar = avatar
        self.firstName = firstName
        self.familyName = familyName
        self.username = username
        self.usernameCorrupted = usernameCorrupted
        self.usernameLink = usernameLink
        self.usernameLinkCorrupted = usernameLinkCorrupted
        self.hasCompletedUsernameLinkOnboarding = hasCompletedUsernameLinkOnboarding
        self.userAvatarData = userAvatarData
        _editState = editState
        _usernameEditState = usernameEditState
        self.actions = actions
        self.renderSubpage = renderSubpage
    }

    /// `getFullNameText`
    var fullName: String { [firstName, familyName ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }

    var title: String {
        switch editState {
        case .betterAvatar: i18n("icu:ProfileEditorModal--avatar")
        case .bio: i18n("icu:ProfileEditorModal--about")
        case .none: i18n("icu:ProfileEditorModal--profile")
        case .profileName: i18n("icu:ProfileEditorModal--name")
        case .username: i18n("icu:ProfileEditorModal--username")
        case .usernameLink: i18n("icu:ProfileEditorModal--sharing")
        }
    }

    func back() { editState = .none }

    @ViewBuilder var usernameAccessory: some View {
        if usernameEditState == .deleting {
            AxoItem.IconAction(label: i18n("icu:ProfileEditor--username--deleting-username"), variant: .impliedSecondary, symbol: "more", pending: true)
        } else if usernameCorrupted {
            AxoSymbol.Icon("error-circle", size: 20, label: i18n("icu:ProfileEditor__username__error-icon")).cssTextColor(.labelDestructive)
        } else {
            AxoDropdownMenu.Root(isOpen: $usernameMenuOpen) {
                AxoItem.IconAction(label: i18n("icu:ProfileEditor--username--context-menu"), variant: .impliedSecondary, symbol: "more")
            } items: {
                AxoDropdownMenu.Item(i18n("icu:ProfileEditor--username--copy"), symbol: "copy") {
                    if let username { actions.copyUsername(username) }
                }
                AxoDropdownMenu.Item(i18n("icu:ProfileEditor--username--delete"), symbol: "trash") { usernameEditState = .confirmingDelete }
            }
        }
    }

    @ViewBuilder var usernameLinkRow: some View {
        if let username, !username.isEmpty, !usernameCorrupted {
            let row = AxoClickableItem.Root(symbol: "qrcode", label: i18n("icu:ProfileEditor__username-link"), onClick: {
                actions.markCompletedUsernameLinkOnboarding()
                if usernameLinkCorrupted { isResettingUsernameLink = true } else { editState = .usernameLink }
            }) {
                if usernameLinkCorrupted {
                    AxoSymbol.Icon("error-circle", size: 20, label: i18n("icu:ProfileEditor__username-link__error-icon")).cssTextColor(.labelDestructive)
                }
            }
            if !hasCompletedUsernameLinkOnboarding && usernameLink == nil {
                row.overlay(alignment: .bottom) {
                    UsernameLinkTooltip(onClose: actions.markCompletedUsernameLinkOnboarding).alignmentGuide(.bottom) { $0[.top] }
                }
            } else {
                row
            }
        }
    }

    var mainPage: some View {
        VStack(spacing: 0) {
            AvatarPreview(avatarColor: color, avatarImage: avatar, hasAvatar: avatar != nil, conversationTitle: fullName, size: 80) {
                editState = .betterAvatar
            }
            // .ProfileEditor__EditPhotoContainer: centred, margin-bottom 16
            AxoButton.Root(i18n("icu:ProfileEditor--edit-photo"), variant: .strongSecondary, size: .sm) { editState = .betterAvatar }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            AxoList.Group {
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            AxoClickableItem.Root(symbol: "person", label: fullName) { editState = .profileName }
                            AxoItem.Root {
                                AxoItem.Leading {
                                    if let aboutEmoji, !aboutEmoji.isEmpty {
                                        FunStaticEmoji(aboutEmoji, size: 24)
                                    } else {
                                        AxoItem.Icon(symbol: "pencil")
                                    }
                                }
                                AxoItem.Content {
                                    AxoItem.Label(aboutText.flatMap { $0.isEmpty ? nil : $0 } ?? i18n("icu:ProfileEditor--about"))
                                    AxoItem.HiddenTrigger(label: i18n("icu:ProfileEditor--about")) { editState = .bio }
                                }
                            }
                        }
                    }
                    AxoList.Footer { AxoList.FooterDescription(i18n("icu:ProfileEditor--info--general")) }
                }
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            AxoClickableItem.Root(symbol: "at", label: (!usernameCorrupted ? username : nil) ?? i18n("icu:ProfileEditor--username"), onClick: {
                                if usernameCorrupted {
                                    isResettingUsername = true
                                } else {
                                    actions.openUsernameReservationModal()
                                    editState = .username
                                }
                            }) { usernameAccessory }
                            usernameLinkRow
                        }
                    }
                    AxoList.Footer {
                        AxoList.FooterDescription(i18n(username != nil ? "icu:ProfileEditor--info--pnp" : "icu:ProfileEditor--info--pnp--no-username"))
                    }
                }
            }
        }
    }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header {
                if editState != .none { AxoPanel.Back(onClick: back) }
                AxoPanel.Label(title)
            }
            AxoPanel.Content {
                switch editState {
                case .none:
                    mainPage
                case .betterAvatar:
                    AvatarEditor(avatarColor: color, avatarImage: avatar, conversationTitle: fullName, isGroup: false, userAvatarData: userAvatarData,
                                 callbacks: {
                                     var c = actions.avatarEditor
                                     let cancel = c.onCancel, save = c.onSave
                                     c.onCancel = { cancel(); back() }
                                     c.onSave = { save($0); back() }
                                     return c
                                 }())
                default:
                    renderSubpage(editState, back)
                }
            }
        }
        .viewportPortal {
            if usernameEditState == .confirmingDelete {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:ProfileEditor--username--confirm-delete-body-2", ["username": .string(username ?? "")])) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { usernameEditState = .editing }
                        AxoConfirmDialog.Action(i18n("icu:ProfileEditor--username--confirm-delete-button"), variant: .strongDestructive) {
                            actions.deleteUsername()
                        }
                    }
                }
            } else if isResettingUsernameLink {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:UsernameLinkModalBody__error__text")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { isResettingUsernameLink = false }
                        AxoConfirmDialog.Action(i18n("icu:UsernameLinkModalBody__error__fix-now"), variant: .subtleSecondary) {
                            isResettingUsernameLink = false
                            editState = .usernameLink
                        }
                    }
                }
            } else if isResettingUsername {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:ProfileEditor--username--corrupted--body")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { isResettingUsername = false }
                        AxoConfirmDialog.Action(i18n("icu:ProfileEditor--username--corrupted--fix-button"), variant: .strongPrimary) {
                            isResettingUsername = false
                            actions.openUsernameReservationModal()
                            editState = .username
                        }
                    }
                }
            }
        }
    }
}

/// `UsernameLinkTooltip`: the "Share your username" bubble under the link row until the
/// onboarding is marked done.
struct UsernameLinkTooltip: View {
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SignalIcon("v3/qr_code/qr_code", size: 24, color: .labelPrimary)
            VStack(alignment: .leading, spacing: 4) {
                CSSText(i18n("icu:ProfileEditor__username-link__tooltip__title"), style: LegacyType.body1(weight: 600), color: .labelPrimary)
                CSSText(i18n("icu:ProfileEditor__username-link__tooltip__body"), style: LegacyType.body2(), color: .labelSecondary)
            }
            SwiftUI.Button(action: onClose) { SignalIcon("v3/x/x", size: 16, color: .labelSecondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:close"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray75)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray60), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 6)
        .frame(maxWidth: 300)
    }
}

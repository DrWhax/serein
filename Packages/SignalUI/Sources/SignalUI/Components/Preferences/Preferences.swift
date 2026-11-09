// Port of ts/components/Preferences.dom.tsx (stylesheets/components/Preferences.scss): the
// Settings tab — a NavSidebar with the profile chip and the page buttons, and the selected
// page beside it. Donations and Backups are omitted (with those features), so their buttons
// are not shown.

import SignalI18n
import SwiftUI

/// `SettingsPage`
public enum SettingsPage: String, Sendable, CaseIterable {
    case profile = "Profile", account = "Account", accountKeys = "AccountKeys", general = "General", signalPinAdvanced = "SignalPinAdvanced"
    case appearance = "Appearance", chatColor = "ChatColor", chats = "Chats", chatFolders = "ChatFolders", editChatFolder = "EditChatFolder"
    case calls = "Calls", notifications = "Notifications", whileMuted = "WhileMuted", notificationProfilesHome = "NotificationProfilesHome"
    case notificationProfilesCreateFlow = "NotificationProfilesCreateFlow"
    case privacy = "Privacy", pnp = "PNP", blocked = "Blocked", dataUsage = "DataUsage", `internal` = "Internal"
}

/// The NavSidebar header's nav-tabs toggle state (Preferences props `navTabsCollapsed`,
/// `hasFailedStorySends`, `hasPendingUpdate`, `otherTabsUnreadCount`).
public struct NavSidebarNavTabs {
    public var collapsed = false
    public var hasFailedStorySends = false
    public var hasPendingUpdate = false
    public var otherTabsUnreadCount = 0
    public var onToggleCollapse: (Bool) -> Void = { _ in }
    public init(collapsed: Bool = false, hasFailedStorySends: Bool = false, hasPendingUpdate: Bool = false, otherTabsUnreadCount: Int = 0,
                onToggleCollapse: @escaping (Bool) -> Void = { _ in }) {
        self.collapsed = collapsed
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.otherTabsUnreadCount = otherTabsUnreadCount
        self.onToggleCollapse = onToggleCollapse
    }
}

/// The profile chip's conversation (`me`).
public struct PreferencesMe: Sendable {
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var phoneNumber: String?
    public var username: String?
    public init(title: String, color: String = "A200", avatar: RGBAImage? = nil, phoneNumber: String? = nil, username: String? = nil) {
        self.title = title
        self.color = color
        self.avatar = avatar
        self.phoneNumber = phoneNumber
        self.username = username
    }
}

public struct Preferences<Page: View>: View {
    let me: PreferencesMe
    @Binding var page: SettingsPage
    let weArePrimaryDevice: Bool
    let hasPhoneNumber: Bool
    let isInternalUser: Bool
    let preferredWidth: CGFloat
    let onOpenUsernameLink: () -> Void
    let navTabs: NavSidebarNavTabs
    /// `renderUpdateDialog` when `shouldShowUpdateDialog` (above the page selector).
    let updateDialog: AnyView?
    let pageContent: (SettingsPage) -> Page
    @Environment(\.i18n) var i18n

    public init(me: PreferencesMe, page: Binding<SettingsPage>, weArePrimaryDevice: Bool = false, hasPhoneNumber: Bool = true, isInternalUser: Bool = false,
                preferredWidth: CGFloat = 300, onOpenUsernameLink: @escaping () -> Void = {}, navTabs: NavSidebarNavTabs = NavSidebarNavTabs(),
                updateDialog: AnyView? = nil, @ViewBuilder pageContent: @escaping (SettingsPage) -> Page) {
        self.navTabs = navTabs
        self.updateDialog = updateDialog
        self.me = me
        _page = page
        self.weArePrimaryDevice = weArePrimaryDevice
        self.hasPhoneNumber = hasPhoneNumber
        self.isInternalUser = isInternalUser
        self.preferredWidth = preferredWidth
        self.onOpenUsernameLink = onOpenUsernameLink
        self.pageContent = pageContent
    }

    public var body: some View {
        HStack(spacing: 0) {
            NavSidebar(title: i18n("icu:Preferences--header"), hasFailedStorySends: navTabs.hasFailedStorySends, hasPendingUpdate: navTabs.hasPendingUpdate,
                       navTabsCollapsed: navTabs.collapsed, onToggleNavTabsCollapse: navTabs.onToggleCollapse, preferredLeftPaneWidth: preferredWidth,
                       requiresFullWidth: true, otherTabsUnreadCount: navTabs.otherTabsUnreadCount) {
                EmptyView()
            } content: {
                pageSelector
            }
            pageContent(page).id(page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AxoColor.surfacePrimary)
        .overlay(alignment: .top) { TitlebarDragArea() }
    }

    /// `__page-selector` (pt 2) / `__scroll-area` (11px inline). The rows' `my-0.5` margins
    /// collapse (2px between rows, 4px after the chip, 8px around the divider).
    /// `.Preferences__page-selector`: the update dialog (`__dialog-container`, mb 8) over the list.
    var pageSelector: some View {
        VStack(spacing: 0) {
            if let updateDialog { updateDialog.padding(.bottom, 8) }
            pageList
        }
    }

    var pageList: some View {
        let showAccount = !weArePrimaryDevice || !hasPhoneNumber
        return AxoDialog.AxoScrollContainer {
            VStack(alignment: .leading, spacing: 2) {
                profileChip.padding(.bottom, 2)
                if showAccount {
                    button("person-circle", "icu:Preferences__button--account", [.account, .accountKeys], .account)
                }
                Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).padding(.horizontal, 14).padding(.top, showAccount ? 6 : 4).padding(.bottom, 6)
                button("settings", "icu:Preferences__button--general", [.general, .signalPinAdvanced], .general)
                button("appearance", "icu:Preferences__button--appearance", [.appearance, .chatColor], .appearance)
                button("message", "icu:Preferences__button--chats", [.chats], .chats)
                button("phone", "icu:Preferences__button--calls", [.calls], .calls)
                button("bell", "icu:Preferences__button--notifications", [.notifications, .whileMuted, .notificationProfilesHome, .notificationProfilesCreateFlow], .notifications)
                button("lock", "icu:Preferences__button--privacy", [.privacy, .pnp, .blocked], .privacy)
                button("piechart", "icu:Preferences__button--data-usage", [.dataUsage], .dataUsage)
                if isInternalUser { button("bolt", "icu:Preferences__button--internal", [.internal], .internal) }
            }
            .padding(.bottom, 2)
            .padding(.horizontal, 11)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 2)
    }

    /// `__profile-chip`: avatar, name / number / username, the QR button.
    var profileChip: some View {
        let selected = page == .profile
        return HStack(alignment: .center, spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: me.title, size: 48, conversationType: .direct, color: me.color,
                   image: me.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: me.avatar != nil)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 0) {
                CSSText(me.title, style: LegacyType.body1(weight: 700), wrap: .truncate, color: .labelPrimary)
                if let phone = me.phoneNumber { CSSText(phone, style: LegacyType.bodySmall(), wrap: .truncate, color: .labelPrimary).padding(.top, 2) }
                if let username = me.username { CSSText(username, style: LegacyType.bodySmall(), wrap: .truncate, color: .labelPrimary).padding(.top, 2) }
            }
            .padding(.top, -4).padding(.bottom, -5)
            .frame(maxWidth: .infinity, alignment: .leading)
            if me.username != nil {
                Button(action: onOpenUsernameLink) {
                    SignalIcon("v3/qr_code/qr_code", size: 20, color: .labelPrimary, mask: true)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AxoColor.fillPrimary))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .accessibilityLabel(i18n("icu:ProfileEditor__username-link__open"))
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? AxoColor.fillPrimaryPressed : AxoColor(RGBA(0, 0, 0, 0))))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { page = .profile }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(i18n("icu:ProfileEditor__open"))
    }

    /// `PreferencesButton`: an 18px icon and the label, `aria-current` filled.
    func button(_ symbol: AxoSymbol.Name, _ key: String, _ current: Set<SettingsPage>, _ target: SettingsPage) -> some View {
        PreferencesButton(symbol: symbol, label: i18n(key), current: current.contains(page)) { page = target }
    }
}

struct PreferencesButton: View {
    let symbol: AxoSymbol.Name
    let label: String
    let current: Bool
    let onClick: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                AxoSymbol.Icon(symbol, size: 18, label: nil)
                CSSText(label, style: LegacyType.body1())
            }
            .cssTextColor(.labelPrimary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(current ? AxoColor.fillPrimaryPressed : hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// Port of ts/components/NavTabs.dom.tsx + stylesheets/components/NavTabs.scss: the 80px
// vertical tab rail (menu toggle, Chats, Calls, Stories, Settings) beside the tab panel.

import SignalI18n
import SwiftUI

public enum NavTab: String, Sendable, CaseIterable { case chats, calls, stories, settings }

/// `NavTabsItemBadges`: error "!", update dot, or unread count.
struct NavTabsItemBadges: View {
    let hasError: Bool
    let hasPendingUpdate: Bool
    let unreadCount: Int
    var body: some View {
        if hasError {
            unread("!")
        } else if hasPendingUpdate {
            // .NavTabs__ItemUpdateBadge: 8px accent dot, 1px surface-secondary ring, at the icon's top-end
            Circle().fill(AxoColor.labelAccent)
                .overlay(Circle().strokeBorder(AxoColor.surfaceSecondary, lineWidth: 1))
                .frame(width: 8, height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        } else if unreadCount > 0 {
            unread("\(unreadCount)")
        }
    }

    /// .NavTabs__ItemUnreadBadge: 16px pill, 10px text, at inset-inline-end −6, top −4.
    func unread(_ s: String) -> some View {
        CSSText(s, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 10, lineHeight: 16, letterSpacing: -0.084), wrap: .nowrap,
                color: .labelPrimaryOncolor)
            .padding(.horizontal, 2)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(AxoColor.labelDestructive))
            .fixedSize()
            .alignmentGuide(.top) { _ in 4 }
            .alignmentGuide(.trailing) { d in d.width - 6 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// One `.NavTabs__Item`: padding 2/10, rounded-8 button with 10px block padding and a 20px icon.
struct NavTabsItem: View {
    let icon: String
    let filledIcon: String?
    let label: String
    let selected: Bool
    var hasError = false
    var hasPendingUpdate = false
    var unreadCount = 0
    let action: () -> Void
    @State private var hovered = false
    @GestureState private var pressed = false

    var body: some View {
        let active = selected || pressed
        ZStack {
            SignalIcon(active ? (filledIcon ?? icon) : icon, size: 20, color: .labelPrimary)
                .overlay { NavTabsItemBadges(hasError: hasError, hasPendingUpdate: hasPendingUpdate, unreadCount: unreadCount) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background {
            if active { RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimaryPressed) }
            else if hovered { RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimary) }
        }
        .padding(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { _ in action() })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `NavTabsToggle`: the menu button that collapses/expands the rail.
public struct NavTabsToggle: View {
    let collapsed: Bool
    let hasFailedStorySends: Bool
    let hasPendingUpdate: Bool
    let otherTabsUnreadCount: Int
    let onToggle: (Bool) -> Void
    @Environment(\.i18n) var i18n
    @State private var hovered = false

    public init(collapsed: Bool, hasFailedStorySends: Bool = false, hasPendingUpdate: Bool = false, otherTabsUnreadCount: Int = 0,
                onToggle: @escaping (Bool) -> Void) {
        self.collapsed = collapsed
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.otherTabsUnreadCount = otherTabsUnreadCount
        self.onToggle = onToggle
    }

    public var body: some View {
        // .NavTabs__Toggle: block padding 2 + 10 − 4; button padding 4, radius 4, centred.
        SignalIcon("v3/menu/menu", size: 20, color: .labelPrimary)
            .overlay { NavTabsItemBadges(hasError: hasFailedStorySends, hasPendingUpdate: hasPendingUpdate, unreadCount: otherTabsUnreadCount) }
            .padding(4)
            .background { if hovered { RoundedRectangle(cornerRadius: 4).fill(AxoColor.fillPrimary) } }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { onToggle(!collapsed) }
            .accessibilityElement()
            .accessibilityLabel(i18n(collapsed ? "icu:NavTabsToggle__showTabs" : "icu:NavTabsToggle__hideTabs"))
            .accessibilityAddTraits(.isButton)
    }
}

/// `<NavTabs>`
public struct NavTabs<Panel: View>: View {
    let selected: NavTab
    let collapsed: Bool
    let storiesEnabled: Bool
    let hasPendingUpdate: Bool
    let hasFailedStorySends: Bool
    let unreadChats: Int
    let unreadCalls: Int
    let unreadStories: Int
    let onSelect: (NavTab) -> Void
    let onToggleCollapse: (Bool) -> Void
    let panel: (NavTab) -> Panel
    @Environment(\.i18n) var i18n
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight

    public init(selected: NavTab, collapsed: Bool = false, storiesEnabled: Bool = false, hasPendingUpdate: Bool = false, hasFailedStorySends: Bool = false,
                unreadChats: Int = 0, unreadCalls: Int = 0, unreadStories: Int = 0, onSelect: @escaping (NavTab) -> Void = { _ in },
                onToggleCollapse: @escaping (Bool) -> Void = { _ in }, @ViewBuilder panel: @escaping (NavTab) -> Panel) {
        self.selected = selected
        self.collapsed = collapsed
        self.storiesEnabled = storiesEnabled
        self.hasPendingUpdate = hasPendingUpdate
        self.hasFailedStorySends = hasFailedStorySends
        self.unreadChats = unreadChats
        self.unreadCalls = unreadCalls
        self.unreadStories = unreadStories
        self.onSelect = onSelect
        self.onToggleCollapse = onToggleCollapse
        self.panel = panel
    }

    public var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                VStack(spacing: 0) {
                    NavTabsToggle(collapsed: collapsed, onToggle: onToggleCollapse)
                    NavTabsItem(icon: "v3/chat/chat", filledIcon: "v3/chat/chat-fill", label: i18n("icu:NavTabs__ItemLabel--Chats"),
                                selected: selected == .chats, unreadCount: unreadChats) { onSelect(.chats) }
                    NavTabsItem(icon: "v3/phone/phone", filledIcon: "v3/phone/phone-fill", label: i18n("icu:NavTabs__ItemLabel--Calls"),
                                selected: selected == .calls, unreadCount: unreadCalls) { onSelect(.calls) }
                    if storiesEnabled {
                        NavTabsItem(icon: "v3/stories/stories", filledIcon: "v3/stories/stories-fill", label: i18n("icu:NavTabs__ItemLabel--Stories"),
                                    selected: selected == .stories, hasError: hasFailedStorySends, unreadCount: unreadStories) { onSelect(.stories) }
                    }
                    Spacer(minLength: 0)                                                 // grid row 1fr
                    NavTabsItem(icon: "v3/settings/settings", filledIcon: "v3/settings/settings-fill", label: i18n("icu:NavTabs__ItemLabel--Settings"),
                                selected: selected == .settings, hasPendingUpdate: hasPendingUpdate) { onSelect(.settings) }
                }
                .padding(.top, dragAreaHeight)
                .padding(.bottom, 8)
                .frame(width: 79)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(AxoColor.surfaceSecondary)
                .overlay(alignment: .trailing) { Rectangle().fill(AxoColor.borderPrimary).frame(width: 1).offset(x: 1) }
                .padding(.trailing, 1)
            }
            panel(selected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

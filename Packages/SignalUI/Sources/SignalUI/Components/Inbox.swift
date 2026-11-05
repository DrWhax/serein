// Inbox (ts/components/Inbox.dom.tsx): the NavTabs rail with the selected tab beside it.

import SwiftUI

public struct Inbox<Tab: View, Modal: View>: View {
    let navTabs: NavTabsState
    let renderTab: (NavTab) -> Tab
    let activeModal: Modal?

    public init(navTabs: NavTabsState, @ViewBuilder renderTab: @escaping (NavTab) -> Tab, activeModal: Modal? = nil) {
        self.navTabs = navTabs
        self.renderTab = renderTab
        self.activeModal = activeModal
    }

    public var body: some View {
        NavTabs(selected: navTabs.selected, collapsed: navTabs.collapsed, storiesEnabled: navTabs.storiesEnabled,
                hasPendingUpdate: navTabs.hasPendingUpdate, hasFailedStorySends: navTabs.hasFailedStorySends,
                unreadChats: navTabs.unreadChats, unreadCalls: navTabs.unreadCalls, unreadStories: navTabs.unreadStories,
                onSelect: navTabs.onSelect, onToggleCollapse: navTabs.onToggleCollapse, panel: renderTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if let activeModal { activeModal } }
    }
}

extension Inbox where Modal == EmptyView {
    public init(navTabs: NavTabsState, @ViewBuilder renderTab: @escaping (NavTab) -> Tab) {
        self.init(navTabs: navTabs, renderTab: renderTab, activeModal: nil)
    }
}

/// The SmartNavTabs props Inbox forwards to NavTabs.
public struct NavTabsState {
    public var selected: NavTab
    public var collapsed: Bool
    public var storiesEnabled: Bool
    public var hasPendingUpdate: Bool
    public var hasFailedStorySends: Bool
    public var unreadChats: Int
    public var unreadCalls: Int
    public var unreadStories: Int
    public var onSelect: (NavTab) -> Void
    public var onToggleCollapse: (Bool) -> Void

    public init(selected: NavTab, collapsed: Bool = false, storiesEnabled: Bool = false, hasPendingUpdate: Bool = false,
                hasFailedStorySends: Bool = false, unreadChats: Int = 0, unreadCalls: Int = 0, unreadStories: Int = 0,
                onSelect: @escaping (NavTab) -> Void = { _ in }, onToggleCollapse: @escaping (Bool) -> Void = { _ in }) {
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
    }
}

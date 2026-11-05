// NavSidebar (ts/components/NavSidebar.dom.tsx, stylesheets/components/NavSidebar.scss): the
// resizable column beside the NavTabs rail that hosts each tab's list (chats, calls, stories,
// settings), with its header (title, actions, back button) and the drag handle.

import SignalI18n
import SwiftUI

/// `ts/util/leftPaneWidth.std.ts`
public enum LeftPaneWidth {
    public static let minWidth: CGFloat = 97
    static let snapWidth: CGFloat = 200
    public static let minFullWidth: CGFloat = 280
    public static let maxWidth: CGFloat = 380

    public static func fromPreferred(_ preferred: CGFloat, requiresFullWidth: Bool) -> CGFloat {
        let clamped = min(max(preferred, minWidth), maxWidth)
        if requiresFullWidth || clamped >= snapWidth { return max(clamped, minFullWidth) }
        return minWidth
    }
}

/// `ts/components/_util.std.ts` WidthBreakpoint.
public enum WidthBreakpoint: String, Sendable {
    case wide, medium, narrow

    public static func navSidebar(_ width: CGFloat) -> WidthBreakpoint { width >= 150 ? .wide : .narrow }
}

extension EnvironmentValues {
    /// `NavSidebarWidthBreakpointContext`
    @Entry public var navSidebarWidthBreakpoint: WidthBreakpoint? = nil
    /// `--title-bar-drag-area-height`: 28 on macOS outside full screen (the hidden title bar's
    /// traffic-light strip), 0 otherwise (and in Storybook).
    @Entry public var titleBarDragAreaHeight: CGFloat = 0
}

public struct NavSidebar<Actions: View, Content: View, Toasts: View>: View {
    let title: String
    let hideHeader: Bool
    let hasFailedStorySends: Bool
    let hasPendingUpdate: Bool
    let navTabsCollapsed: Bool
    let onBack: (() -> Void)?
    let onToggleNavTabsCollapse: (Bool) -> Void
    let preferredLeftPaneWidth: CGFloat
    let requiresFullWidth: Bool
    let savePreferredLeftPaneWidth: (CGFloat) -> Void
    let otherTabsUnreadCount: Int
    let actions: Actions?
    let content: Content
    let renderToastManager: (WidthBreakpoint, @escaping () -> Void) -> Toasts

    @Environment(\.i18n) var i18n
    @Environment(\.layoutDirection) var direction
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    @State private var preferredWidth: CGFloat?
    @State private var dragging = false
    @State private var dragStartWidth: CGFloat = 0
    @FocusState private var handleFocused: Bool

    public init(title: String, hideHeader: Bool = false, hasFailedStorySends: Bool = false, hasPendingUpdate: Bool = false,
                navTabsCollapsed: Bool = false, onBack: (() -> Void)? = nil, onToggleNavTabsCollapse: @escaping (Bool) -> Void = { _ in },
                preferredLeftPaneWidth: CGFloat, requiresFullWidth: Bool = false,
                savePreferredLeftPaneWidth: @escaping (CGFloat) -> Void = { _ in }, otherTabsUnreadCount: Int = 0,
                @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content,
                renderToastManager: @escaping (WidthBreakpoint, @escaping () -> Void) -> Toasts) {
        self.title = title
        self.hideHeader = hideHeader
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.navTabsCollapsed = navTabsCollapsed
        self.onBack = onBack
        self.onToggleNavTabsCollapse = onToggleNavTabsCollapse
        self.preferredLeftPaneWidth = preferredLeftPaneWidth
        self.requiresFullWidth = requiresFullWidth
        self.savePreferredLeftPaneWidth = savePreferredLeftPaneWidth
        self.otherTabsUnreadCount = otherTabsUnreadCount
        let a = actions()
        self.actions = a is EmptyView ? nil : a
        self.content = content()
        self.renderToastManager = renderToastManager
    }

    var currentPreferred: CGFloat {
        preferredWidth ?? LeftPaneWidth.fromPreferred(preferredLeftPaneWidth, requiresFullWidth: requiresFullWidth)
    }
    var width: CGFloat { LeftPaneWidth.fromPreferred(currentPreferred, requiresFullWidth: requiresFullWidth) }
    var breakpoint: WidthBreakpoint { WidthBreakpoint.navSidebar(width) }
    var narrow: Bool { breakpoint == .narrow }

    public var body: some View {
        VStack(spacing: 0) {
            if !hideHeader {
                AxoDragRegion.Root { header }
            }
            ZStack(alignment: .top) { Color.clear; content }    // __Content: flex 1 1 0%
        }
        .padding(.top, dragAreaHeight)
        .padding(.trailing, 1)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(AxoColor.surfaceSecondary)
        .overlay(alignment: .trailing) { Rectangle().fill(AxoColor.borderPrimary).frame(width: 1) }    // border-inline-end
        .overlay(alignment: .trailing) {
            dragHandle.alignmentGuide(HorizontalAlignment.trailing) { $0[.leading] }    // inset-inline-start: 100%
        }
        .overlay { renderToastManager(breakpoint, expandNarrowLeftPane) }
        .environment(\.navSidebarWidthBreakpoint, breakpoint)
        .environment(\.searchInputMarginReset, true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// font-title-medium with line-height 20.
    static var headerTitleStyle: CSSTextStyle {
        var s = LegacyType.titleMedium()
        s.lineHeight = 20
        return s
    }

    // MARK: header

    @ViewBuilder var header: some View {
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .center, spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            if onBack == nil && navTabsCollapsed {
                NavTabsToggle(collapsed: navTabsCollapsed, hasFailedStorySends: hasFailedStorySends, hasPendingUpdate: hasPendingUpdate,
                              otherTabsUnreadCount: otherTabsUnreadCount, onToggle: onToggleNavTabsCollapse)
                    .frame(width: 80)
            }
            headerContent
        }
        .padding(.bottom, 6)
    }

    var headerContent: some View {
        let start: CGFloat = narrow ? 0 : onBack != nil ? 16 : navTabsCollapsed ? 0 : 24
        return HStack(alignment: .center, spacing: 0) {
            if let onBack {
                NavSidebarBackButton(label: i18n("icu:NavSidebar__BackButtonLabel"), action: onBack)
                    .padding(.vertical, -4)
            }
            if narrow {
                // sr-only: no layout presence.
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isHeader)
            } else if onBack != nil {
                CSSText(title, style: LegacyType.body1(weight: 600), alignment: .center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            } else {
                CSSText(title, style: Self.headerTitleStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            if let actions {
                let stack = narrow ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                stack { actions }.padding(.vertical, -4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)    // NavTabs__Item__blockPadding + NavTabs__ItemButton__blockPadding
        .padding(.leading, start)
        .padding(.trailing, narrow ? 0 : 24)
        .cssTextColor(.labelPrimary)
    }

    // MARK: drag handle

    func expandNarrowLeftPane() {
        if currentPreferred < LeftPaneWidth.minFullWidth {
            preferredWidth = LeftPaneWidth.minFullWidth
            savePreferredLeftPaneWidth(LeftPaneWidth.minFullWidth)
        }
    }

    /// `useMove` with the pointer: the preferred width follows the drag (unsnapped), and the
    /// snapped width is saved when the drag ends.
    var dragHandle: some View {
        Rectangle()
            .fill(dragging ? AxoColor.fillPrimaryPressed : AxoColor(RGBA(0, 0, 0, 0)))
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .axoFocusRing(handleFocused, in: Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        if !dragging { dragging = true; dragStartWidth = currentPreferred }
                        let dx = direction == .rightToLeft ? -g.translation.width : g.translation.width
                        preferredWidth = dragStartWidth + dx
                    }
                    .onEnded { _ in endMove() }
            )
            .focusable(interactions: .activate)    // keyboard navigation only, never initial focus
            .focusEffectDisabled()
            .focused($handleFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let visual: CGFloat = press.key == .rightArrow ? 1 : -1
                let dx = direction == .rightToLeft ? -visual : visual
                let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                let prev = currentPreferred
                if prev == LeftPaneWidth.minFullWidth && dx < 0 {
                    preferredWidth = LeftPaneWidth.minWidth    // jump minimize
                } else if prev == LeftPaneWidth.minWidth && dx > 0 {
                    preferredWidth = LeftPaneWidth.minFullWidth    // jump maximize
                } else {
                    preferredWidth = prev + dx * step
                }
                endMove()
                return .handled
            }
            .accessibilityElement()
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { dir in
                preferredWidth = currentPreferred + (dir == .increment ? 10 : -10)
                endMove()
            }
    }

    func endMove() {
        dragging = false
        let w = width
        preferredWidth = w
        savePreferredLeftPaneWidth(w)
    }
}

extension NavSidebar where Toasts == EmptyView {
    public init(title: String, hideHeader: Bool = false, hasFailedStorySends: Bool = false, hasPendingUpdate: Bool = false,
                navTabsCollapsed: Bool = false, onBack: (() -> Void)? = nil, onToggleNavTabsCollapse: @escaping (Bool) -> Void = { _ in },
                preferredLeftPaneWidth: CGFloat, requiresFullWidth: Bool = false,
                savePreferredLeftPaneWidth: @escaping (CGFloat) -> Void = { _ in }, otherTabsUnreadCount: Int = 0,
                @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.init(title: title, hideHeader: hideHeader, hasFailedStorySends: hasFailedStorySends, hasPendingUpdate: hasPendingUpdate,
                  navTabsCollapsed: navTabsCollapsed, onBack: onBack, onToggleNavTabsCollapse: onToggleNavTabsCollapse,
                  preferredLeftPaneWidth: preferredLeftPaneWidth, requiresFullWidth: requiresFullWidth,
                  savePreferredLeftPaneWidth: savePreferredLeftPaneWidth, otherTabsUnreadCount: otherTabsUnreadCount,
                  actions: actions, content: content, renderToastManager: { _, _ in EmptyView() })
    }
}

/// `NavSidebarBackButton`: implied-secondary sm icon button with chevron-[start].
public struct NavSidebarBackButton: View {
    let label: String
    let disabled: Bool
    let action: () -> Void
    public init(label: String, disabled: Bool = false, action: @escaping () -> Void = {}) {
        self.label = label
        self.disabled = disabled
        self.action = action
    }
    public var body: some View {
        AxoIconButton.Root(label: label, variant: .impliedSecondary, size: .sm, symbol: "chevron-[start]", disabled: disabled, action: action)
    }
}

/// `NavSidebarSearchHeader`: margin-inline 16, margin-bottom 8, gap 12 (the search input grows).
public struct NavSidebarSearchHeader<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}

/// `NavSidebarEmpty`: centred title + subtitle overlaying the sidebar (hidden when narrow).
public struct NavSidebarEmpty: View {
    let title: String
    let subtitle: String
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint
    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
    public var body: some View {
        if breakpoint != .narrow {
            VStack(spacing: 0) {
                CSSText(title, style: LegacyType.titleMedium(), alignment: .center, color: .labelPrimary)
                    .padding(.bottom, 6)
                CSSText(subtitle, style: LegacyType.body1(), alignment: .center, color: .labelSecondary)
            }
            .padding(.top, 100)
            .padding(.bottom, 28)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }
}

// SearchInput (ts/components/SearchInput.dom.tsx, stylesheets/components/SearchInput.scss) and
// LeftPaneSearchInput (ts/components/LeftPaneSearchInput.dom.tsx): the 28px rounded search
// box with its magnifier, clear button and optional leading children (the in-conversation
// pill). At rest the value / placeholder is CSSText; a plain TextField takes over while
// editing (ImageRenderer cannot draw TextField, and Text does not lay out like Chromium).

import SignalI18n
import SwiftUI

public struct SearchInput<Children: View>: View {
    @Binding var value: String
    let placeholder: String?
    let label: String?
    let disabled: Bool
    let hasSearchIcon: Bool
    let noMargin: Bool
    let description: String?
    let childrenInset: CGFloat?
    let children: Children
    let onClear: (() -> Void)?
    let onBlur: () -> Void
    let onEnter: () -> Void
    let selectsOnAppear: Bool
    let focusesOnAppear: Bool
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var isStatic
    @Environment(\.searchInputMarginReset) var marginReset
    @Environment(\.searchInputInlinePadding) var inlinePadding
    @State private var editing = false
    @FocusState private var liveFocused: Bool

    /// - Parameter childrenInset: the input's padding-inline-start when `children` sit inside it
    ///   (LeftPaneSearchInput: 50px).
    public init(value: Binding<String>, placeholder: String? = nil, label: String? = nil, disabled: Bool = false, hasSearchIcon: Bool = true,
                noMargin: Bool = false, description: String? = nil, childrenInset: CGFloat? = nil, selectsOnAppear: Bool = false,
                focusesOnAppear: Bool = false, onClear: (() -> Void)? = nil, onBlur: @escaping () -> Void = {}, onEnter: @escaping () -> Void = {},
                @ViewBuilder children: () -> Children) {
        _value = value
        self.selectsOnAppear = selectsOnAppear
        self.focusesOnAppear = focusesOnAppear
        self.placeholder = placeholder
        self.label = label
        self.disabled = disabled
        self.hasSearchIcon = hasSearchIcon
        self.noMargin = noMargin
        self.description = description
        self.childrenInset = childrenInset
        self.onClear = onClear
        self.onBlur = onBlur
        self.onEnter = onEnter
        self.children = children()
    }

    static var textStyle: CSSTextStyle { LegacyType.body2() }
    /// Chromium's focused-input ::selection colours.
    static var selectionColor: AxoColor { AxoColor(light: RGBA(hex: 0xABCFF6), dark: RGBA(hex: 0x3A5777)) }

    static func selectedRun(_ text: String) -> CSSTextRun {
        var run = CSSTextRun(text, color: .labelPrimary)
        run.background = selectionColor
        return run
    }

    /// Snapshots show the state right after `select()`: focused, the whole value selected.
    var staticSelected: Bool { isStatic && selectsOnAppear }
    var staticFocused: Bool { isStatic && (selectsOnAppear || focusesOnAppear) }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let hasText = !value.isEmpty
        let leading = inlinePadding ?? childrenInset ?? 30
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                shape.fill(AxoColor.fillPrimary)
                ZStack(alignment: .leading) {
                    if !(editing && !isStatic) || value.isEmpty {
                        if staticSelected && hasText {
                            CSSText(runs: [Self.selectedRun(value)], style: Self.textStyle, wrap: .nowrap)
                        } else {
                            CSSText(hasText ? value : (placeholder ?? ""), style: Self.textStyle, wrap: .nowrap,
                                    color: hasText ? .labelPrimary : .labelPlaceholder)
                                .opacity(editing && !isStatic && hasText ? 0 : 1)
                        }
                    }
                    if editing && !isStatic { live }
                }
                .padding(.leading, leading)
                .padding(.trailing, inlinePadding ?? (hasText ? 30 : 5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                if hasSearchIcon {
                    SignalIcon("v3/search/search-compact-light", size: 16, color: .labelSecondary)
                        .frame(width: 16, height: 16)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
                children
                if hasText, let onClear {
                    SwiftUI.Button(action: onClear) {
                        SignalIcon("v3/x/x-compact", size: 16, color: .labelSecondary).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:cancel"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 28)
            .contentShape(shape)
            .onTapGesture { if !disabled { editing = true } }
            .axoFocusRing((editing && !isStatic) || staticFocused, in: shape)
            .onAppear { if (selectsOnAppear || focusesOnAppear) && !isStatic { editing = true } }
            .opacity(disabled ? 0.5 : 1)
            if let description {
                CSSText(description, style: LegacyType.subtitle(), color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05))
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, noMargin || marginReset ? 0 : 16)
        .padding(.bottom, noMargin || marginReset ? 0 : 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label ?? i18n("icu:search"))
    }

    var live: some View {
        TextField("", text: $value)
            .textFieldStyle(.plain)
            .font(AxoFonts.inter(size: 13))
            .foregroundStyle(AxoColor.labelPrimary)
            .focused($liveFocused)
            .onAppear { liveFocused = true }
            .onChange(of: liveFocused) { _, focused in
                if !focused {
                    editing = false
                    onBlur()
                }
            }
            .onSubmit(onEnter)
            .onExitCommand { onClear?() }
    }
}

extension EnvironmentValues {
    /// `.NavSidebar .module-SearchInput__container { margin: 0 }`
    @Entry var searchInputMarginReset = false
    /// `.LeftPaneFindBy…Helper__search-input .module-SearchInput__input { padding-inline: 12px }`
    @Entry var searchInputInlinePadding: CGFloat? = nil
}

extension SearchInput where Children == EmptyView {
    public init(value: Binding<String>, placeholder: String? = nil, label: String? = nil, disabled: Bool = false, hasSearchIcon: Bool = true,
                noMargin: Bool = false, description: String? = nil, selectsOnAppear: Bool = false, focusesOnAppear: Bool = false,
                onClear: (() -> Void)? = nil, onBlur: @escaping () -> Void = {}, onEnter: @escaping () -> Void = {}) {
        self.init(value: value, placeholder: placeholder, label: label, disabled: disabled, hasSearchIcon: hasSearchIcon, noMargin: noMargin,
                  description: description, selectsOnAppear: selectsOnAppear, focusesOnAppear: focusesOnAppear, onClear: onClear,
                  onBlur: onBlur, onEnter: onEnter) { EmptyView() }
    }
}

/// The conversation being searched in (LeftPaneSearchInput's pill).
public struct SearchConversation {
    public var id: String
    public var avatar: ConversationAvatarData
    public init(id: String, avatar: ConversationAvatarData) {
        self.id = id
        self.avatar = avatar
    }
}

public struct LeftPaneSearchInput: View {
    @Binding var searchTerm: String
    let searchConversation: SearchConversation?
    let disabled: Bool
    let isSearchingGlobally: Bool
    let filterButtonEnabled: Bool
    let filterPressed: Bool
    let onFilterClick: (Bool) -> Void
    let clearSearchQuery: () -> Void
    let endConversationSearch: () -> Void
    let endSearch: () -> Void
    let onEnterKeyDown: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint

    public init(searchTerm: Binding<String>, searchConversation: SearchConversation? = nil, disabled: Bool = false,
                isSearchingGlobally: Bool = false, filterButtonEnabled: Bool = false, filterPressed: Bool = false, onFilterClick: @escaping (Bool) -> Void = { _ in },
                clearSearchQuery: @escaping () -> Void = {}, endConversationSearch: @escaping () -> Void = {},
                endSearch: @escaping () -> Void = {}, onEnterKeyDown: @escaping () -> Void = {}) {
        _searchTerm = searchTerm
        self.searchConversation = searchConversation
        self.disabled = disabled
        self.isSearchingGlobally = isSearchingGlobally
        self.filterButtonEnabled = filterButtonEnabled
        self.filterPressed = filterPressed
        self.onFilterClick = onFilterClick
        self.clearSearchQuery = clearSearchQuery
        self.endConversationSearch = endConversationSearch
        self.endSearch = endSearch
        self.onEnterKeyDown = onEnterKeyDown
    }

    var label: String {
        if searchConversation != nil { return i18n("icu:searchIn") }
        if filterPressed { return i18n("icu:searchUnreadChats") }
        return i18n("icu:search")
    }

    public var body: some View {
        // Fragment children of NavSidebarSearchHeader (flex, gap 12).
        HStack(spacing: 12) {
            if breakpoint != .narrow {    // .module-left-pane--width-narrow: display none
                SearchInput(value: $searchTerm, placeholder: label, label: label, disabled: disabled, hasSearchIcon: searchConversation == nil,
                            childrenInset: searchConversation != nil ? 50 : nil,
                            // Focused (and its text selected) when a global search starts or a
                            // conversation search begins.
                            selectsOnAppear: isSearchingGlobally || searchConversation != nil,
                            onClear: {
                                clearSearchQuery()
                                endConversationSearch()
                            },
                            onBlur: { if searchConversation == nil && searchTerm.isEmpty { endSearch() } },
                            onEnter: onEnterKeyDown) {
                    if let searchConversation { pill(searchConversation) }
                }
            }
            if filterButtonEnabled {
                AxoIconButton.Root(label: i18n("icu:filterByUnreadButtonLabel"), variant: .impliedSecondary, size: .sm, symbol: "filter",
                                   pressed: filterPressed) { onFilterClick(!filterPressed) }
                    .padding(.trailing, 8)
                    .fixedSize()
            }
        }
    }

    /// `__in-conversation-pill`: a rounded 20px avatar + 16px x (inset 4 / 3).
    func pill(_ c: SearchConversation) -> some View {
        HStack(spacing: 0) {
            ListAvatar(data: c.avatar, size: 20)
            SwiftUI.Button(action: endConversationSearch) {
                SignalIcon("v3/x/x", size: 16, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .accessibilityLabel(i18n("icu:clearSearch"))
        }
        .padding(.trailing, 3)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray80)))
        .padding(.vertical, 4)
        .padding(.leading, 3)
    }
}

// Port of ts/axo/items/AxoContactList.dom.tsx: a titled list of contacts (avatar, name,
// truncated about/description, optional value and actions) in `sm` item spacing.

import SwiftUI

public enum AxoContactList {
    /// `<AxoContactList.Root>`
    public struct Root<Content: View>: View {
        let title: [AxoInlinePiece]?
        let titleView: AnyView?
        let content: Content
        public init(title: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title.map { [.text($0)] }
            self.titleView = nil
            self.content = content()
        }
        /// A title node of its own (AxoList.Label's h2 is type-body-medium semibold; the node sets its own fonts).
        public init(titleView: AnyView, @ViewBuilder content: () -> Content) {
            self.title = nil
            self.titleView = titleView
            self.content = content()
        }
        /// A title of mixed inline content (text and symbol glyphs).
        public init(titlePieces: [AxoInlinePiece], @ViewBuilder content: () -> Content) {
            self.title = titlePieces
            self.titleView = nil
            self.content = content()
        }
        public var body: some View {
            AxoList.Root {
                if let title {
                    AxoList.Header { AxoList.Label(pieces: title) }
                } else if let titleView {
                    AxoList.Header {
                        titleView
                            .cssTextColor(.labelPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                AxoList.Body {
                    AxoBaseItem.Group(spacing: .sm) { content }
                        .accessibilityElement(children: .contain)
                }
            }
        }
    }

    /// `<AxoContactList.Item>`. The description truncates to one line unless
    /// `allowDescriptionOverflow`.
    public struct Item<Avatar: View, Description: View, Accessory: View>: View {
        let avatar: Avatar
        let title: String
        /// Rich title content in place of the plain title (the accessibility label stays `title`).
        let titleView: AnyView?
        let value: String?
        let valueView: AnyView?
        let description: Description?
        let allowDescriptionOverflow: Bool
        let accessory: Accessory?
        let onClick: (() -> Void)?

        public init(title: String, titleView: AnyView? = nil, value: String? = nil, valueView: AnyView? = nil, allowDescriptionOverflow: Bool = false,
                    onClick: (() -> Void)? = nil, @ViewBuilder avatar: () -> Avatar, @ViewBuilder description: () -> Description,
                    @ViewBuilder accessory: () -> Accessory) {
            self.avatar = avatar()
            self.title = title
            self.titleView = titleView
            self.value = value
            self.valueView = valueView
            let d = description()
            self.description = d is EmptyView ? nil : d
            self.allowDescriptionOverflow = allowDescriptionOverflow
            let a = accessory()
            self.accessory = a is EmptyView ? nil : a
            self.onClick = onClick
        }

        public var body: some View {
            AxoBaseItem.Root(accessibilityLabel: title) {
                AxoBaseItem.Leading { avatar }
                AxoBaseItem.Content {
                    if let titleView { AxoBaseItem.Label { titleView } } else { AxoBaseItem.Label(title) }
                    if let value { AxoBaseItem.Value(value) }
                    if let valueView { AxoBaseItem.Value { valueView } }
                    if let description {
                        AxoBaseItem.Description { description }
                            .environment(\.axoContactListDescriptionWrap, allowDescriptionOverflow ? .wrap : .truncate)
                    }
                    if let onClick { AxoBaseItem.HiddenTrigger(label: title, action: onClick) }
                    if let accessory { AxoBaseItem.Accessory { accessory } }
                }
            }
        }
    }

    /// A description string, truncated (or wrapped) as its `Item` asks.
    public struct DescriptionText: View {
        let text: String
        @Environment(\.axoContactListDescriptionWrap) var wrap
        public init(_ text: String) { self.text = text }
        public var body: some View { AxoBaseItem.Text(text, type: .bodySmall, wrap: wrap) }
    }

    struct DescriptionWrapKey: EnvironmentKey { static let defaultValue = CSSTextWrap.truncate }

    public enum ItemActionVariant: String, Sendable, CaseIterable { case subtleSecondary = "subtle-secondary" }

    /// `<AxoContactList.ItemAction>`
    public struct ItemAction: View {
        let label: String
        let variant: ItemActionVariant
        let action: () -> Void
        public init(_ label: String, variant: ItemActionVariant, action: @escaping () -> Void = {}) {
            self.label = label
            self.variant = variant
            self.action = action
        }
        public var body: some View { AxoBaseItem.Action(label, variant: .subtleSecondary, action: action) }
    }

    public enum ItemIconActionVariant: String, Sendable, CaseIterable { case impliedSecondary = "implied-secondary" }

    /// `<AxoContactList.ItemIconAction>`
    public struct ItemIconAction: View {
        let label: String
        let variant: ItemIconActionVariant
        let symbol: AxoSymbol.Name
        let tooltip: Bool
        let action: () -> Void
        public init(label: String, variant: ItemIconActionVariant, symbol: AxoSymbol.Name, tooltip: Bool = true,
                    action: @escaping () -> Void = {}) {
            self.label = label
            self.variant = variant
            self.symbol = symbol
            self.tooltip = tooltip
            self.action = action
        }
        public var body: some View {
            AxoBaseItem.IconAction(label: label, variant: .impliedSecondary, symbol: symbol, tooltip: tooltip, action: action)
        }
    }

    /// `<AxoContactList.ActionItem>`: a 32px icon avatar and a title.
    public struct ActionItem: View {
        let symbol: AxoSymbol.Name
        let title: String
        let onClick: (() -> Void)?
        public init(symbol: AxoSymbol.Name, title: String, onClick: (() -> Void)? = nil) {
            self.symbol = symbol
            self.title = title
            self.onClick = onClick
        }
        public var body: some View {
            AxoBaseItem.Root(accessibilityLabel: title) {
                AxoBaseItem.Leading { AxoBaseItem.IconAvatar(size: 32, symbol: symbol) }
                AxoBaseItem.Content {
                    AxoBaseItem.Label(title)
                    if let onClick { AxoBaseItem.HiddenTrigger(label: title, action: onClick) }
                }
            }
        }
    }

    /// `<AxoContactList.EmptyStateItem>`: a truncated text-secondary label.
    public struct EmptyStateItem: View {
        let title: String
        public init(title: String) { self.title = title }
        public var body: some View {
            AxoBaseItem.Root {
                AxoBaseItem.Content {
                    AxoBaseItem.Label { AxoBaseItem.Text(title, type: .bodyMedium, wrap: .truncate).cssTextColor(.labelSecondary) }
                }
            }
        }
    }
}

extension AxoContactList.Item where Description == EmptyView {
    public init(title: String, value: String? = nil, onClick: (() -> Void)? = nil, @ViewBuilder avatar: () -> Avatar,
                @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, value: value, onClick: onClick, avatar: avatar, description: { EmptyView() }, accessory: accessory)
    }
}

extension AxoContactList.Item where Accessory == EmptyView {
    public init(title: String, value: String? = nil, allowDescriptionOverflow: Bool = false, onClick: (() -> Void)? = nil,
                @ViewBuilder avatar: () -> Avatar, @ViewBuilder description: () -> Description) {
        self.init(title: title, value: value, allowDescriptionOverflow: allowDescriptionOverflow, onClick: onClick, avatar: avatar,
                  description: description, accessory: { EmptyView() })
    }
}

extension AxoContactList.Item where Description == EmptyView, Accessory == EmptyView {
    public init(title: String, value: String? = nil, onClick: (() -> Void)? = nil, @ViewBuilder avatar: () -> Avatar) {
        self.init(title: title, value: value, onClick: onClick, avatar: avatar, description: { EmptyView() }, accessory: { EmptyView() })
    }
}

extension EnvironmentValues {
    var axoContactListDescriptionWrap: CSSTextWrap {
        get { self[AxoContactList.DescriptionWrapKey.self] }
        set { self[AxoContactList.DescriptionWrapKey.self] = newValue }
    }
}

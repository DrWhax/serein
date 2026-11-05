// Port of ts/axo/items/AxoItem.dom.tsx: the public list item (an ARIA list of
// AxoBaseItem rows). Same anatomy as upstream:
//
//   AxoItem.Group > AxoItem.Root > AxoItem.Leading (Icon | IconAvatar)
//                                > AxoItem.Content (Label, Value, Description, HiddenTrigger,
//                                                   Accessory (Action | IconAction | …), Trailing (Arrow))

import SwiftUI

public enum AxoItem {
    public typealias Spacing = AxoBaseItem.Spacing
    public typealias Variant = AxoBaseItem.Variant
    public typealias IconAvatarSize = AxoBaseItem.IconAvatarSize
    public typealias ActionVariant = AxoBaseItem.ActionVariant
    public typealias IconActionVariant = AxoBaseItem.IconActionVariant
    public typealias ArrowKind = AxoBaseItem.ArrowKind

    /// `<AxoItem.Group>` (spacing defaults to `md`)
    public struct Group<Content: View>: View {
        let spacing: Spacing
        let content: Content
        public init(spacing: Spacing = .md, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.content = content()
        }
        public var body: some View {
            AxoBaseItem.Group(spacing: spacing) { content }
                .accessibilityElement(children: .contain)
        }
    }

    /// `<AxoItem.Root>`
    public struct Root<Content: View>: View {
        let variant: Variant
        let disabled: Bool
        let content: Content
        public init(variant: Variant = .secondary, disabled: Bool = false, @ViewBuilder content: () -> Content) {
            self.variant = variant
            self.disabled = disabled
            self.content = content()
        }
        public var body: some View {
            AxoBaseItem.Root(variant: variant, disabled: disabled) { content }
        }
    }

    public typealias Leading = AxoBaseItem.Leading
    public typealias Icon = AxoBaseItem.Icon
    public typealias IconAvatar = AxoBaseItem.IconAvatar
    public typealias Content = AxoBaseItem.Content
    public typealias Label = AxoBaseItem.Label
    public typealias Value = AxoBaseItem.Value
    public typealias Description = AxoBaseItem.Description
    public typealias HiddenTrigger = AxoBaseItem.HiddenTrigger
    public typealias Accessory = AxoBaseItem.Accessory
    public typealias Action = AxoBaseItem.Action
    public typealias IconAction = AxoBaseItem.IconAction
    public typealias Trailing = AxoBaseItem.Trailing
    public typealias Arrow = AxoBaseItem.Arrow
}

// Port of ts/axo/AxoMenuBuilder.dom.tsx: one menu definition rendered either as a dropdown
// menu (opened from its trigger) or as a context menu (opened by right-click at the
// pointer). The items are the shared menu items.

import SwiftUI

public enum AxoMenuBuilder {
    /// `AxoMenuBuilder.Renderer`
    public enum Renderer: String, Sendable { case dropdownMenu = "AxoDropdownMenu", contextMenu = "AxoContextMenu" }

    /// `<AxoMenuBuilder.Root>` + Trigger + Content. `isOpen` drives the dropdown renderer;
    /// `location` (the right-click point) the context menu.
    public struct Root<Trigger: View, Items: View>: View {
        let renderer: Renderer
        @Binding var isOpen: Bool
        @Binding var location: CGPoint?
        let trigger: Trigger
        let items: Items

        public init(renderer: Renderer, isOpen: Binding<Bool> = .constant(false), location: Binding<CGPoint?> = .constant(nil),
                    @ViewBuilder trigger: () -> Trigger, @ViewBuilder items: () -> Items) {
            self.renderer = renderer
            _isOpen = isOpen
            _location = location
            self.trigger = trigger()
            self.items = items()
        }

        public var body: some View {
            switch renderer {
            case .dropdownMenu: AxoDropdownMenu.Root(isOpen: $isOpen) { trigger } items: { items }
            case .contextMenu: AxoContextMenu.Root(location: $location) { trigger } items: { items }
            }
        }
    }

    public typealias Item = AxoDropdownMenu.Item
    public typealias CheckboxItem = AxoDropdownMenu.CheckboxItem
    public typealias RadioGroup = AxoDropdownMenu.RadioGroup
    public typealias RadioItem = AxoDropdownMenu.RadioItem
    public typealias SubTrigger = AxoDropdownMenu.SubTrigger
    public typealias Sub = AxoDropdownMenu.Sub
    public typealias Label = AxoBaseMenu.Label
    public typealias Separator = AxoBaseMenu.Separator
    public typealias Header = AxoBaseMenu.Header
}

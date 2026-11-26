// Port of ts/axo/AxoContextMenu.dom.tsx (Radix ContextMenu): a menu that opens at the
// pointer — anchored on a zero-size point, side right, align start, sideOffset 2,
// alignOffset −6, collision padding 6 — with the same items as AxoDropdownMenu.

import SwiftUI

public enum AxoContextMenu {
    /// `<AxoContextMenu.Root>` + Trigger + Content. `location` is the pointer position in
    /// the trigger's coordinates (set by a secondary click; nil = closed).
    public struct Root<Trigger: View, Items: View>: View {
        @Binding var location: CGPoint?
        let trigger: Trigger
        let items: Items
        @State private var id = UUID().uuidString
        @Environment(\.axoStaticRendering) var isStatic

        public init(location: Binding<CGPoint?>, @ViewBuilder trigger: () -> Trigger, @ViewBuilder items: () -> Items) {
            _location = location
            self.trigger = trigger()
            self.items = items()
        }

        public var body: some View {
            trigger
                .onSecondaryClick(isEnabled: !isStatic) { location = $0 }
                .overlay(alignment: .topLeading) {
                    if let location {
                        // A zero-size anchor at the pointer (padding moves its layout frame,
                        // which anchors use; .offset would only move the drawing).
                        Color.clear.frame(width: 0, height: 0)
                            .axoPopper(id: id, isPresented: true,
                                       placement: AxoPopper.Placement(side: .right, align: .start, sideOffset: 2, alignOffset: -6, collisionPadding: 6),
                                       dismiss: { self.location = nil }) {
                                AxoBaseMenu.Content { items }.environment(\.axoMenuClose, AxoMenuAction(run: { self.location = nil }))
                            }
                            .padding(.leading, location.x)
                            .padding(.top, location.y)
                    }
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

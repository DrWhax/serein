// Port of ts/axo/AxoContextMenu.dom.tsx (Radix ContextMenu): a menu that opens at the
// pointer — anchored on a zero-size point, side right, align start, sideOffset 2,
// alignOffset −6, collision padding 6 — with the same items as AxoDropdownMenu.

import AppKit
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
                .overlay { if !isStatic { SecondaryClickCatcher { location = $0 } } }
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

/// Reports secondary (right / control) clicks with their location; passes other events through.
struct SecondaryClickCatcher: NSViewRepresentable {
    let onClick: @MainActor (CGPoint) -> Void

    final class CatcherView: NSView {
        var onClick: @MainActor (CGPoint) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func rightMouseDown(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil)) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onClick(convert(event.locationInWindow, from: nil)) } else { super.mouseDown(with: event) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim secondary clicks; primary clicks go to the SwiftUI content below.
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onClick = onClick }
}

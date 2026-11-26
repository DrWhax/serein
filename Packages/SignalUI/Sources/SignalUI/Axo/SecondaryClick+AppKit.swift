#if canImport(AppKit)
import AppKit
import SwiftUI

extension View {
    func onSecondaryClick(isEnabled: Bool, perform: @escaping @MainActor (CGPoint) -> Void) -> some View {
        overlay { if isEnabled { SecondaryClickCatcher(onClick: perform) } }
    }
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
#endif

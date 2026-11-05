// `axo-focus-ring` (ts/axo/_tailwind-theme/focus-rings.css): ring-offset 1.5px in
// border-focused-inner, then ring 2.5px in border-focused-outer, outside the element.

import SwiftUI

struct AxoFocusRingModifier<S: InsettableShape>: ViewModifier {
    let visible: Bool
    let shape: S
    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                ZStack {
                    shape.inset(by: -1.5).strokeBorder(AxoColor.borderFocusedInner, lineWidth: 1.5)
                    shape.inset(by: -4).strokeBorder(AxoColor.borderFocusedOuter, lineWidth: 2.5)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    public func axoFocusRing(_ visible: Bool, in shape: some InsettableShape) -> some View {
        modifier(AxoFocusRingModifier(visible: visible, shape: shape))
    }
}

/// Focus-visible handling shared by Axo controls: a control marked `autoFocus` (Radix
/// moves focus to it when a dialog opens) shows its ring until focus moves elsewhere.
struct AxoFocusState: DynamicProperty {
    @FocusState var focused: Bool
    @State var autoFocusConsumed = false
    func visible(autoFocus: Bool) -> Bool { focused || (autoFocus && !autoFocusConsumed) }
}

/// `axo-focus-ring-inset`: 2.5px border-focused-outer at the edge, then 1.5px
/// border-focused-inner inside it.
struct AxoFocusRingInsetModifier<S: InsettableShape>: ViewModifier {
    let visible: Bool
    let shape: S
    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                ZStack {
                    shape.strokeBorder(AxoColor.borderFocusedOuter, lineWidth: 2.5)
                    shape.inset(by: 2.5).strokeBorder(AxoColor.borderFocusedInner, lineWidth: 1.5)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    public func axoFocusRingInset(_ visible: Bool, in shape: some InsettableShape) -> some View {
        modifier(AxoFocusRingInsetModifier(visible: visible, shape: shape))
    }
}

// InlineNotificationWrapper (ts/components/conversation/InlineNotificationWrapper.dom.tsx +
// `.module-inline-notification-wrapper`): a timeline notification row, focusable; in select
// mode the whole row toggles selection and shows the round select checkbox 16px from the
// start, vertically centred (selected: ultramarine at 8% behind the row).

import SwiftUI

public struct InlineNotificationWrapper<Content: View>: View {
    let isSelectMode: Bool
    let isSelected: Bool
    let toggleSelectMessage: (_ shift: Bool, _ selected: Bool) -> Void
    let content: Content

    public init(isSelectMode: Bool = false, isSelected: Bool = false, toggleSelectMessage: @escaping (Bool, Bool) -> Void = { _, _ in },
                @ViewBuilder content: () -> Content) {
        self.isSelectMode = isSelectMode
        self.isSelected = isSelected
        self.toggleSelectMessage = toggleSelectMessage
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if isSelectMode { MessageSelectCheckbox(isSelected: isSelected).padding(.leading, 16) }
            }
            .background(isSelectMode && isSelected ? AxoColor(RGBA(LegacyColor.ultramarine.r, LegacyColor.ultramarine.g, LegacyColor.ultramarine.b, 0.08)) : AxoColor(RGBA(0, 0, 0, 0)))
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectMode { toggleSelectMessage(NSEvent.modifierFlags.contains(.shift), !isSelected) }
            }
            .focusable(interactions: .activate)
            .accessibilityAddTraits(isSelectMode ? .isToggle : [])
            .accessibilityValue(isSelectMode ? (isSelected ? "1" : "0") : "")
    }
}

/// `.module-message__select-checkbox`: a 20px circle, 1px gray-20 border; selected:
/// ultramarine with a 14px white check.
public struct MessageSelectCheckbox: View {
    let isSelected: Bool
    public init(isSelected: Bool) { self.isSelected = isSelected }
    public var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(AxoColor(LegacyColor.ultramarine))
                SignalIcon("v3/check/check-compact-bold", size: 14, color: AxoColor(LegacyColor.white))
            } else {
                Circle().strokeBorder(AxoColor(LegacyColor.gray20), lineWidth: 1)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("Select")
    }
}

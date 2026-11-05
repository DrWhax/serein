// Port of ts/components/fun/FunPicker.dom.tsx + base/FunTabs.dom.tsx (+ FunTabs.scss): the
// composer's combined picker. A 352 × 524 popover with a 48px tab list (Emoji, Stickers,
// GIFs: equal-width pill tabs, body-1, the selected one on fill-primary-pressed) over the
// selected panel. ⌘⇧J / ⌘⇧O / ⌘⇧G open it on the emoji, sticker and GIF tab.

import SignalI18n
import SwiftUI

/// `FunPickerTabKey`
public enum FunPickerTabKey: Sendable, Hashable { case emojis, stickers, gifs }

public struct FunPicker<Emojis: View, Stickers: View, Gifs: View>: View {
    @Binding var tab: FunPickerTabKey
    let emojis: Emojis
    let stickers: Stickers
    let gifs: Gifs
    @Environment(\.i18n) var i18n

    public init(tab: Binding<FunPickerTabKey>, @ViewBuilder emojis: () -> Emojis, @ViewBuilder stickers: () -> Stickers, @ViewBuilder gifs: () -> Gifs) {
        _tab = tab
        self.emojis = emojis()
        self.stickers = stickers()
        self.gifs = gifs()
    }

    public var body: some View {
        FunPopoverDialog {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    FunTab(label: i18n("icu:FunPicker__Tab--Emojis"), isSelected: tab == .emojis) { tab = .emojis }
                    FunTab(label: i18n("icu:FunPicker__Tab--Stickers"), isSelected: tab == .stickers) { tab = .stickers }
                    FunTab(label: i18n("icu:FunPicker__Tab--Gifs"), isSelected: tab == .gifs) { tab = .gifs }
                }
                .padding(.horizontal, 10)
                .frame(height: FunMetrics.tabsListHeight)
                Group {
                    switch tab {
                    case .emojis: emojis
                    case .stickers: stickers
                    case .gifs: gifs
                    }
                }
                .environment(\.funPanelInTabs, true)
            }
            .frame(width: FunMetrics.dialogWidth, height: FunMetrics.dialogHeight)
        }
        .background {
            // Keyboard shortcuts that switch tabs.
            Group {
                SwiftUI.Button("") { tab = .emojis }.keyboardShortcut("j", modifiers: [.command, .shift])
                SwiftUI.Button("") { tab = .stickers }.keyboardShortcut("o", modifiers: [.command, .shift])
                SwiftUI.Button("") { tab = .gifs }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// `FunTabs__Tab` / `__TabButton`: flex 1, 12px × 2px padding; the pill 5px × 12px.
struct FunTab: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        SwiftUI.Button(action: action) {
            CSSText(label, style: LegacyType.body1(), wrap: .nowrap, alignment: .center, color: .labelPrimary)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(isSelected ? AxoColor.fillPrimaryPressed : hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.vertical, 12)
        .padding(.horizontal, 2)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

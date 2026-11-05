// ShortcutGuide (ts/components/ShortcutGuide.dom.tsx, stylesheets/components/ShortcutGuide.scss):
// the keyboard-shortcut sheet. The data and the key-label mapping are upstream's, verbatim.

import SignalI18n
import SwiftUI

public struct ShortcutGuide: View {
    /// Upstream's `platform` prop (`process.platform`): "darwin" shows the macOS keys.
    let platform: String
    let close: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var isStatic
    @FocusState private var scrollFocused: Bool
    @State private var focusConsumed = false

    public init(platform: String = "darwin", close: @escaping () -> Void) {
        self.platform = platform
        self.close = close
    }

    var isMacOS: Bool { platform == "darwin" }

    static var color: AxoColor { AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05) }
    static var background: AxoColor { AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75) }
    static var closeColor: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05) }
    static var rowBorder: AxoColor { AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray90) }
    static var keyBorder: AxoColor { AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray90) }
    /// `mixins.popper-shadow`
    static var popperShadow: [AxoShadowLayer] {
        [AxoShadowLayer(inset: false, x: 0, y: 8, blur: 20, spread: 0, color: RGBA(0, 0, 0, 0.3)),
         AxoShadowLayer(inset: false, x: 0, y: 0, blur: 8, spread: 0, color: RGBA(0, 0, 0, 0.05))]
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Column {
            header
            sections.hidden().accessibilityHidden(true)    // measuring copy for the max-height clamp
            scrollContainer
        }
        .padding(16)
        .background(shape.fill(Self.background))
        .cssBoxShadow(Self.popperShadow, in: shape)
        .cssTextColor(Self.color)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .top)    // margin-inline: auto
    }

    var header: some View {
        HStack(spacing: 0) {
            CSSText(i18n("icu:Keyboard--header"), style: LegacyType.title2(), wrap: .wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
            SwiftUI.Button(action: close) {
                LegacyIcon.Mask(.x, color: Self.closeColor).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(i18n("icu:close-popup"))
            .help(i18n("icu:close-popup"))
        }
        .padding(.bottom, 20)
    }

    /// `__scroll-container` (tabIndex -1, focused on mount by useRestoreFocus, so it shows
    /// Chromium's default focus outline until focus moves elsewhere).
    @ViewBuilder var scrollContainer: some View {
        let outline = RoundedRectangle(cornerRadius: 1.5)
        Group {
            if isStatic {
                AxoDialog.TopAligned { sections }.clipShape(Rectangle())
            } else {
                ScrollView { sections }.scrollIndicators(.automatic)
            }
        }
        .overlay { if !focusConsumed { ChromiumFocusOutline(shape: outline) } }
        .focusable()
        .focusEffectDisabled()
        .focused($scrollFocused)
        .onAppear { scrollFocused = true }
        .onChange(of: scrollFocused) { _, now in if !now { focusConsumed = true } }
    }

    var sections: some View {
        VStack(alignment: .leading, spacing: 25) {
            section("icu:Keyboard--navigation-header", Self.navigation)
            section("icu:Keyboard--messages-header", Self.messages)
            section("icu:Keyboard--composer-header", Self.composer)
            section("icu:Keyboard--calling-header", Self.calling)
        }
    }

    func section(_ titleKey: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText(i18n(titleKey), style: LegacyType.body1(weight: 600))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            ForEach(shortcuts, id: \.id) { row($0) }
        }
    }

    /// `__shortcut`: description, then the key combos right-aligned; min-height 40 including
    /// the 1px bottom border.
    func row(_ shortcut: Shortcut) -> some View {
        let combos = shortcut.macOS.map { isMacOS ? $0 : shortcut.keys } ?? shortcut.keys
        return HStack(alignment: .center, spacing: 0) {
            CSSText(i18n(shortcut.description), style: LegacyType.body1())
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(combos.indices, id: \.self) { i in
                    HStack(spacing: 0) {
                        ForEach(combos[i], id: \.self) { key($0).padding(.leading, 4) }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
            }
            .padding(.bottom, 4)
            .fixedSize()
        }
        .padding(.leading, 4)
        .frame(minHeight: 39)
        .padding(.bottom, 1)
        .background(alignment: .bottom) { Rectangle().fill(Self.rowBorder).frame(height: 1) }
    }

    /// `__shortcut__key` (`--square` for single glyphs): 30 tall, 1px border, radius 2.
    func key(_ key: Key) -> some View {
        let (label, isSquare) = self.label(key)
        let shape = RoundedRectangle(cornerRadius: 2)
        return CSSText(label, style: LegacyType.body1(), wrap: .nowrap, alignment: .center)
            .frame(width: isSquare ? 28 : nil)
            .padding(.horizontal, isSquare ? 1 : 9)    // padding-inline 8 (0 when square) + border
            .padding(.top, 4)                          // padding 3 + border
            .frame(height: 30, alignment: .top)
            .overlay { shape.strokeBorder(Self.keyBorder, lineWidth: 1) }
    }

    func label(_ key: Key) -> (String, Bool) {
        switch key {
        case .commandOrCtrl: isMacOS ? ("⌘", true) : (i18n("icu:Keyboard--Key--ctrl"), false)
        case .ctrlOrAlt: (i18n(isMacOS ? "icu:Keyboard--Key--ctrl" : "icu:Keyboard--Key--alt"), false)
        case .optionOrAlt: (i18n(isMacOS ? "icu:Keyboard--Key--option" : "icu:Keyboard--Key--alt"), false)
        case .ctrl: (i18n("icu:Keyboard--Key--ctrl"), false)
        case .shift: (i18n("icu:Keyboard--Key--shift"), false)
        case .enter: (i18n("icu:Keyboard--Key--enter"), false)
        case .tab: (i18n("icu:Keyboard--Key--tab"), false)
        case .oneToNine: (i18n("icu:Keyboard--Key--one-to-nine-range"), false)
        case .char(let c): (c, true)
        }
    }

    /// Header, measuring copy of the sections, scroll container: the column is as tall as its
    /// content up to the proposed height (`max-height`), and the scroll container takes what
    /// is left after the header.
    struct Column: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 600
            let header = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let content = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let ideal = header + content
            return CGSize(width: width, height: proposal.height.map { min(ideal, $0) } ?? ideal)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let header = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: header))
            subviews[1].place(at: CGPoint(x: bounds.minX - 100_000, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header),
                              proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - header)))
        }
    }
}

extension ShortcutGuide {
    enum Key: Hashable {
        case commandOrCtrl, ctrlOrAlt, optionOrAlt, shift, enter, tab, ctrl, oneToNine
        case char(String)
    }

    struct Shortcut {
        let id: String
        let description: String
        let keys: [[Key]]
        /// `keysByPlatform`: `keys` is then the "other" set.
        var macOS: [[Key]]? = nil
    }

    static func s(_ id: String, _ description: String? = nil, _ keys: [Key]...) -> Shortcut {
        Shortcut(id: id, description: "icu:" + (description ?? id), keys: keys)
    }

    static let navigation: [Shortcut] = [
        s("Keyboard--navigate-by-section", nil, [.commandOrCtrl, .char("T")], [.commandOrCtrl, .char("F6")]),
        s("Keyboard--previous-conversation", nil, [.optionOrAlt, .char("↑")], [.ctrl, .shift, .tab]),
        s("Keyboard--next-conversation", nil, [.optionOrAlt, .char("↓")], [.ctrl, .tab]),
        s("Keyboard--previous-unread-conversation", nil, [.optionOrAlt, .shift, .char("↑")]),
        s("Keyboard--next-unread-conversation", nil, [.optionOrAlt, .shift, .char("↓")]),
        s("Keyboard--conversation-by-index", nil, [.commandOrCtrl, .oneToNine]),
        s("Keyboard--most-recent-message", "Keyboard--focus-most-recent-message", [.commandOrCtrl, .char("J")]),
        s("Keyboard--preferences", nil, [.commandOrCtrl, .char(",")]),
        s("Keyboard--open-conversation-menu", nil, [.commandOrCtrl, .shift, .char("L")]),
        s("Keyboard--new-conversation", nil, [.commandOrCtrl, .char("N")]),
        s("Keyboard--search", nil, [.commandOrCtrl, .char("F")]),
        s("Keyboard--search-in-conversation", nil, [.commandOrCtrl, .shift, .char("F")]),
        s("Keyboard--focus-composer", nil, [.commandOrCtrl, .shift, .char("T")]),
        s("Keyboard--open-all-media-view", nil, [.commandOrCtrl, .shift, .char("M")]),
        s("Keyboard--open-emoji-chooser", nil, [.commandOrCtrl, .shift, .char("J")]),
        s("Keyboard--open-sticker-chooser", nil, [.commandOrCtrl, .shift, .char("O")]),
        s("Keyboard--open-gif-chooser", nil, [.commandOrCtrl, .shift, .char("G")]),
        s("Keyboard--begin-recording-voice-note", nil, [.commandOrCtrl, .shift, .char("Y")]),
        s("Keyboard--archive-conversation", nil, [.commandOrCtrl, .shift, .char("A")]),
        s("Keyboard--unarchive-conversation", nil, [.commandOrCtrl, .shift, .char("U")]),
        s("Keyboard--scroll-to-top", nil, [.commandOrCtrl, .char("↑")]),
        s("Keyboard--scroll-to-bottom", nil, [.commandOrCtrl, .char("↓")]),
        s("Keyboard--close-curent-conversation", nil, [.commandOrCtrl, .shift, .char("C")]),
    ]

    static let messages: [Shortcut] = [
        s("Keyboard--default-message-action", nil, [.enter]),
        s("Keyboard--view-details-for-selected-message", nil, [.commandOrCtrl, .char("D")]),
        s("Keyboard--toggle-reply", nil, [.commandOrCtrl, .shift, .char("R")]),
        s("Keyboard--toggle-reaction-picker", nil, [.commandOrCtrl, .shift, .char("E")]),
        s("Keyboard--save-attachment", nil, [.commandOrCtrl, .char("S")]),
        s("Keyboard--delete-messages", nil, [.commandOrCtrl, .shift, .char("D")]),
        s("Keyboard--forward-messages", nil, [.commandOrCtrl, .shift, .char("S")]),
        Shortcut(id: "Keyboard--open-context-menu", description: "icu:Keyboard--open-context-menu",
                 keys: [[.shift, .char("F10")]], macOS: [[.commandOrCtrl, .char("F12")]]),
    ]

    static let composer: [Shortcut] = [
        s("Keyboard--add-newline", nil, [.shift, .enter]),
        s("Keyboard--expand-composer", nil, [.commandOrCtrl, .shift, .char("K")]),
        s("Keyboard--send-in-expanded-composer", nil, [.commandOrCtrl, .enter]),
        s("Keyboard--attach-file", nil, [.commandOrCtrl, .char("U")]),
        s("Keyboard--remove-draft-link-preview", nil, [.commandOrCtrl, .char("P")]),
        s("Keyboard--remove-draft-attachments", nil, [.commandOrCtrl, .shift, .char("P")]),
        s("Keyboard--edit-last-message", nil, [.char("↑")]),
        s("Keyboard--composer--bold", nil, [.commandOrCtrl, .char("B")]),
        s("Keyboard--composer--italic", nil, [.commandOrCtrl, .char("I")]),
        s("Keyboard--composer--strikethrough", nil, [.commandOrCtrl, .shift, .char("X")]),
        s("Keyboard--composer--monospace", nil, [.commandOrCtrl, .char("E")]),
        s("Keyboard--composer--spoiler", nil, [.commandOrCtrl, .shift, .char("B")]),
    ]

    static let calling: [Shortcut] = [
        s("Keyboard--toggle-audio", nil, [.shift, .char("M")]),
        s("Keyboard--toggle-video", nil, [.shift, .char("V")]),
        s("Keyboard--toggle-preview", nil, [.shift, .char("P")]),
        s("Keyboard--toggle-raise-hand", nil, [.shift, .char("H")]),
        s("Keyboard--accept-video-call", nil, [.ctrlOrAlt, .shift, .char("V")]),
        s("Keyboard--accept-call-without-video", nil, [.ctrlOrAlt, .shift, .char("A")]),
        s("Keyboard--decline-call", nil, [.ctrlOrAlt, .shift, .char("D")]),
        s("Keyboard--start-audio-call", nil, [.ctrlOrAlt, .shift, .char("C")]),
        s("Keyboard--start-video-call", nil, [.ctrlOrAlt, .shift, .char("Y")]),
        s("Keyboard--hang-up", nil, [.ctrlOrAlt, .shift, .char("E")]),
    ]
}

/// ShortcutGuideModal (ts/components/ShortcutGuideModal.dom.tsx): the guide over a 40% black
/// backdrop with 20px padding, vertically centred (`.module-shortcut-guide-modal`).
public struct ShortcutGuideModal: View {
    let platform: String
    let closeShortcutGuideModal: () -> Void
    public init(platform: String = "darwin", closeShortcutGuideModal: @escaping () -> Void) {
        self.platform = platform
        self.closeShortcutGuideModal = closeShortcutGuideModal
    }
    public var body: some View {
        ShortcutGuide(platform: platform, close: closeShortcutGuideModal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)    // .module-shortcut-guide-container
            .padding(20)
            .background(AxoColor(LegacyColor.blackAlpha40))
            .onExitCommand(perform: closeShortcutGuideModal)
    }
}

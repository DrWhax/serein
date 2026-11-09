// Port of ts/components/TextStoryCreator.dom.tsx (+ stylesheets/components/StoryCreator.scss),
// the text half of StoryCreator: a full-window gray-95 editor with the text story (720×1280
// scaled into the space above the toolbar), and the toolbar — while editing text the tools
// (colour slider, font menu, text background cycle, emoji); then Discard, the background /
// text / link controls and Next (a spinner while sending). The background control opens the
// eight-swatch picker; the link control the link-preview input. Escape closes the open
// picker or editing, else asks to discard.

import SignalI18n
import SignalText
import SwiftUI

/// `LinkPreviewForUIType` as the story creator shows it.
public typealias StoryCreatorLinkPreview = StoryLinkPreviewData

public struct TextStoryCreator: View {
    /// `BackgroundStyle`: five colours, three gradients.
    static let backgrounds: [TextAttachmentData] = [
        TextAttachmentData(color: 4_285_041_620), TextAttachmentData(color: 4_287_006_657), TextAttachmentData(color: 4_290_019_212),
        TextAttachmentData(color: 4_287_205_768), TextAttachmentData(color: 4_283_667_331),
        gradient([0xFF19A9FA, 0xFF7097D7, 0xFFD1998D, 0xFFFFC369]),
        gradient([0xFF4437D8, 0xFF6B70DE, 0xFFB774E0, 0xFFFF8E8E]),
        gradient([0xFF004044, 0xFF2C5F45, 0xFF648E52, 0xFF93B864]),
    ]

    static func gradient(_ colors: [UInt32]) -> TextAttachmentData {
        TextAttachmentData(gradient: StoryGradient(angle: 180, startColor: colors.first, endColor: colors.last, colors: colors,
                                                   positions: [0, 0.33, 0.66, 1]))
    }

    enum TextBackground { case none, background, inverse }
    enum LinkPreviewApplied { case none, automatic, manual }

    let isSending: Bool
    let linkPreview: StoryCreatorLinkPreview?
    let debouncedMaybeGrabLinkPreview: (String) -> Void
    let onClose: () -> Void
    let onDone: (TextAttachmentData) -> Void
    @State private var isEditingText = false
    @State private var selectedBackground = 0
    @State private var textStyle: TextAttachmentStyle = .regular
    @State private var textBackground: TextBackground = .none
    @State private var sliderValue: Double = 100
    @State private var text = ""
    @State private var isColorPickerShowing = false
    @State private var isLinkPreviewInputShowing = false
    @State private var linkPreviewApplied: LinkPreviewApplied = .none
    @State private var linkPreviewInputValue = ""
    @State private var fontMenuOpen = false
    @State private var emojiPickerOpen = false
    @State private var confirmDiscard = false
    @Environment(\.i18n) var i18n

    public init(isSending: Bool = false, linkPreview: StoryCreatorLinkPreview? = nil, debouncedMaybeGrabLinkPreview: @escaping (String) -> Void = { _ in },
                onClose: @escaping () -> Void = {}, onDone: @escaping (TextAttachmentData) -> Void = { _ in }) {
        self.isSending = isSending
        self.linkPreview = linkPreview
        self.debouncedMaybeGrabLinkPreview = debouncedMaybeGrabLinkPreview
        self.onClose = onClose
        self.onDone = onDone
    }

    /// `getRGBANumber`: the slider's colour as an opaque ARGB integer.
    static func argb(_ percentage: Double) -> UInt32 {
        let c = MediaEditorColor.color(percentage)
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return 0xFF00_0000 | byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
    }

    var textAttachment: TextAttachmentData {
        var t = Self.backgrounds[selectedBackground]
        let slider = Self.argb(sliderValue)
        var fg = slider
        var bg: UInt32?
        switch textBackground {
        case .none: break
        case .background:
            bg = StoryColors.white
            fg = sliderValue >= 95 ? StoryColors.black : slider
        case .inverse:
            bg = sliderValue >= 95 ? StoryColors.black : slider
            fg = StoryColors.white
        }
        t.text = text
        t.textStyle = textStyle
        t.textForegroundColor = fg
        t.textBackgroundColor = bg
        t.preview = linkPreviewApplied != .none ? linkPreview : nil
        return t
    }

    var hasChanges: Bool { !text.isEmpty || linkPreviewApplied != .none }

    func onTryClose() { confirmDiscard = true }

    public var body: some View {
        VStack(spacing: 0) {
            // __container: flex 1, 22px × 60px padding, the story centred.
            TextAttachment(textAttachment: textAttachment, onClick: { if !isEditingText { isEditingText = true } },
                           onRemoveLinkPreview: { linkPreviewApplied = .none })
                .editable($text, isEditingText: isEditingText)
                .padding(.vertical, 22).padding(.horizontal, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            toolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(rgba: LegacyColor.gray95))
        .environment(\.colorScheme, .dark)
        .onChange(of: text) { _, now in
            if !now.isEmpty && linkPreviewApplied != .manual { debouncedMaybeGrabLinkPreview(now) }
            updateAutomaticPreview()
        }
        .onChange(of: linkPreview) { _, _ in updateAutomaticPreview() }
        .onChange(of: linkPreviewInputValue) { _, now in
            if !now.isEmpty && linkPreviewApplied != .manual { debouncedMaybeGrabLinkPreview(now) }
        }
        .onExitCommand {
            if isColorPickerShowing || isEditingText || isLinkPreviewInputShowing {
                isColorPickerShowing = false
                isEditingText = false
                isLinkPreviewInputShowing = false
            } else {
                onTryClose()
            }
        }
        .overlay {
            if confirmDiscard {
                ConfirmDiscardDialog(onClose: { confirmDiscard = false }) {
                    confirmDiscard = false
                    onClose()
                }
            }
        }
    }

    /// The preview applies itself while its URL is in the text (unless added by hand).
    func updateAutomaticPreview() {
        guard let linkPreview, !text.isEmpty, linkPreviewApplied != .manual else { return }
        linkPreviewApplied = LinkPreviewRules.findLinks(text).contains(linkPreview.url) ? .automatic : .none
    }

    /// `__toolbar`: 22px padding; the tools (or their 44px space, 22px below), then the buttons.
    var toolbar: some View {
        VStack(spacing: 0) {
            Group {
                if isEditingText { tools } else { Color.clear.frame(width: 0, height: 44) }
            }
            .padding(.bottom, 22)
            HStack(alignment: .center, spacing: 0) {
                LegacyButton(i18n("icu:discard"), variant: .secondary, action: onTryClose)
                    .fixedSize()
                controls
                    .frame(maxWidth: 596)
                nextButton
            }
            .frame(maxWidth: .infinity)
        }
        .padding(22)
    }

    @ViewBuilder var nextButton: some View {
        if isSending {
            LegacyButton(nil, variant: .primary, disabled: true, overrides: LegacyButton.Overrides(height: 40, width: 56)) {}
                .overlay { Spinner(svgSize: .small).allowsHitTesting(false) }
                .fixedSize()
        } else {
            LegacyButton(i18n("icu:StoryCreator__next"), variant: .primary, disabled: !hasChanges) { onDone(textAttachment) }
                .fixedSize()
        }
    }

    /// `__controls`: the background swatch, text and link buttons (32px, 15px apart from each edge).
    var controls: some View {
        HStack(spacing: 0) {
            StoryCreatorBackgroundControl(background: Self.backgrounds[selectedBackground], selected: isColorPickerShowing,
                                          label: i18n("icu:StoryCreator__story-bg")) { isColorPickerShowing.toggle() }
                .padding(.horizontal, 15)
                .overlay(alignment: .top) {
                    if isColorPickerShowing { colorPicker.fixedSize().offset(y: -18).alignmentGuide(.top) { $0[.bottom] } }
                }
            StoryCreatorControl(icon: "v2/text-24", label: i18n("icu:StoryCreator__control--text"), selected: isEditingText) { isEditingText.toggle() }
                .padding(.horizontal, 15)
            StoryCreatorControl(icon: "v3/link/link", label: i18n("icu:StoryCreator__control--link"), selected: false) {
                isLinkPreviewInputShowing.toggle()
            }
            .padding(.horizontal, 15)
            .overlay(alignment: .top) {
                if isLinkPreviewInputShowing { linkPreviewInput.fixedSize().offset(y: -18).alignmentGuide(.top) { $0[.bottom] } }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `__popper` with the eight `__bg` swatches (24px, 4px margin, white 2px ring when chosen).
    var colorPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(32), spacing: 0), count: 4)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Self.backgrounds.indices, id: \.self) { i in
                Button {
                    selectedBackground = i
                    isColorPickerShowing = false
                } label: {
                    StoryColors.background(Self.backgrounds[i])
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(i == selectedBackground ? Color.white : .clear, lineWidth: 2))
                        .frame(width: 24, height: 24)
                        .padding(4)
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel(i18n("icu:StoryCreator__story-bg"))
            }
        }
        .frame(width: 128)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray80)))
        .overlay(alignment: .bottom) { StoryCreatorPopperArrow().offset(y: 14) }
    }

    /// The link-preview popper: the URL input, then the (half-size) preview with "Add link", or
    /// the empty state.
    var linkPreviewInput: some View {
        VStack(spacing: 0) {
            Input(value: $linkPreviewInputValue, placeholder: i18n("icu:StoryCreator__link-preview-placeholder"), clearLabel: i18n("icu:cancel"),
                  disableSpellcheck: true, autoFocus: true)
            VStack(spacing: 0) {
                if let linkPreview {
                    StoryLinkPreview(preview: linkPreview, forceCompactMode: true)
                        .scaleEffect(0.5)
                    LegacyButton(i18n("icu:StoryCreator__add-link"), variant: .primary) {
                        linkPreviewApplied = .manual
                        isLinkPreviewInputShowing = false
                    }
                    .padding(.top, 18).padding(.bottom, 8)
                } else {
                    VStack(spacing: 0) {
                        SignalIcon("v3/link/link", size: 20, color: AxoColor(LegacyColor.gray45), mask: true).frame(width: 20, height: 20)
                        CSSText(i18n("icu:StoryCreator__link-preview-empty"), style: LegacyType.body1(), color: AxoColor(LegacyColor.gray45))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(width: 360)
        .frame(minHeight: 256)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray80)))
        .overlay(alignment: .bottom) { StoryCreatorPopperArrow().offset(y: 14) }
    }

    /// `__tools`: gray-90, 10px corners, 44px tall — the hue slider, font menu, text background
    /// and emoji button.
    var tools: some View {
        HStack(spacing: 0) {
            HueSlider(label: MediaEditorColor.cssRGBA(sliderValue), value: $sliderValue)
                .padding(.trailing, 14)
            AxoDropdownMenu.Root(isOpen: $fontMenuOpen, side: .top) {
                StoryCreatorToolButton(icon: fontIcon, label: fontLabel) {}
            } items: {
                AxoDropdownMenu.RadioGroup(value: Binding(get: { String(textStyle.rawValue) },
                                                          set: { textStyle = $0.flatMap(Int.init).flatMap(TextAttachmentStyle.init) ?? .regular })) {
                    AxoDropdownMenu.RadioItem(i18n("icu:StoryCreator__text--regular"), value: "1")
                    AxoDropdownMenu.RadioItem(i18n("icu:StoryCreator__text--bold"), value: "2")
                    AxoDropdownMenu.RadioItem(i18n("icu:StoryCreator__text--serif"), value: "3")
                    AxoDropdownMenu.RadioItem(i18n("icu:StoryCreator__text--script"), value: "4")
                    AxoDropdownMenu.RadioItem(i18n("icu:StoryCreator__text--condensed"), value: "5")
                }
            }
            StoryCreatorToolButton(icon: textBackground == .none ? "v2/text-effect-off-24" : "v2/text-effect-on-24", label: backgroundLabel) {
                textBackground = switch textBackground {
                case .none: .background
                case .background: .inverse
                case .inverse: .none
                }
            }
            FunEmojiPickerButton(isOpen: $emojiPickerOpen)
        }
        .padding(.vertical, 14).padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray90)))
    }

    var fontIcon: String {
        switch textStyle {
        case .bold: "v3/font/font-bold-compact"
        case .serif: "v3/font/font-serif-compact"
        case .script: "v3/font/font-script-compact"
        case .condensed: "v3/font/font-condensed-compact"
        default: "v3/font/font-regular-compact"
        }
    }

    var fontLabel: String {
        switch textStyle {
        case .bold: i18n("icu:StoryCreator__text--bold")
        case .serif: i18n("icu:StoryCreator__text--serif")
        case .script: i18n("icu:StoryCreator__text--script")
        case .condensed: i18n("icu:StoryCreator__text--condensed")
        default: i18n("icu:StoryCreator__text--regular")
        }
    }

    var backgroundLabel: String {
        switch textBackground {
        case .background: i18n("icu:StoryCreator__text-bg--background")
        case .inverse: i18n("icu:StoryCreator__text-bg--inverse")
        case .none: i18n("icu:StoryCreator__text-bg--none")
        }
    }
}

/// `__control--bg`: a 24px circle of the story's background with a 1.5px white ring (4px
/// while the picker is open).
struct StoryCreatorBackgroundControl: View {
    let background: TextAttachmentData
    let selected: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            StoryColors.background(background)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 4 : 1.5))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityLabel(label)
    }
}

/// `__control`: a 32px round button with its 24px white icon (black on white when selected,
/// gray-80 on hover).
struct StoryCreatorControl: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            SignalIcon(icon, size: 24, color: AxoColor(selected && !hovered ? LegacyColor.black : LegacyColor.white), mask: true)
                .frame(width: 24, height: 24)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovered ? Color(rgba: LegacyColor.gray80) : selected ? Color.white : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// `__tools__icon-button`: 32px, its 20px white icon, pulled 6px into its neighbours.
struct StoryCreatorToolButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SignalIcon(icon, size: 20, color: AxoColor(LegacyColor.white), mask: true)
                .frame(width: 20, height: 20)
                .frame(width: 32, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(UndimmedButtonStyle())
        .padding(.vertical, -6).padding(.leading, -6).padding(.trailing, 8)
        .accessibilityLabel(label)
    }
}

/// `__popper__arrow`: a 28×14 gray-80 triangle under the popper.
struct StoryCreatorPopperArrow: View {
    var body: some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 28, y: 0))
            p.addLine(to: CGPoint(x: 14, y: 14))
            p.closeSubpath()
        }
        .fill(Color(rgba: LegacyColor.gray80))
        .frame(width: 28, height: 14)
    }
}

extension MediaEditorColor {
    /// `getRGBA`: "rgba(r,g,b,1)".
    static func cssRGBA(_ percentage: Double) -> String {
        let c = color(percentage)
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return "rgba(\(byte(c.r)),\(byte(c.g)),\(byte(c.b)),1)"
    }
}

// Ports of ts/components/ChatColorPicker.dom.tsx (stylesheets/components/ChatColorPicker.scss)
// and SampleMessageBubbles.dom.tsx: the chat colour panel. Three sample messages in a card
// (outgoing gradients span the card, like `background-attachment: fixed`), then the 22 preset
// bubbles, the custom colours (selected: a "…" menu to edit / duplicate / delete) and "+"
// (the custom colour editor), and the reset rows.

import SignalI18n
import SwiftUI

/// `ChatStyle.CustomChatColor`
public struct CustomChatColor: Identifiable, Sendable, Hashable {
    public var id: Int
    public var color: BubbleColor
    public init(id: Int, color: BubbleColor) {
        self.id = id
        self.color = color
    }

    /// `getCustomColorBackground`: a gradient's stored angle maps to `270 − angle` degrees.
    public static func gradient(angle: Double, start: RGBA, end: RGBA) -> BubbleColor {
        .gradient(CSSLinearGradient(deg: 270 - angle, start: start, end: end))
    }
}

/// `ConversationColors`
public enum ConversationColors {
    public static let all = ["ultramarine", "crimson", "vermilion", "burlap", "forest", "wintergreen", "teal", "blue", "indigo", "violet",
                             "plum", "taupe", "steel", "ember", "midnight", "infrared", "lagoon", "fluorescent", "basil", "sublime",
                             "sea", "tangerine"]
}

/// `SampleMessage`: a static bubble (text over its metadata line) in a message row.
struct SampleMessage: View {
    let bubbleColor: BubbleColor
    let direction: MessageDirection
    let text: String
    let timestamp: Date
    let status: MessageStatus

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18))
        VStack(alignment: .trailing, spacing: 0) {
            CSSText(text, style: LegacyType.body1(), wrap: .wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
            MessageMetadata(direction: direction, timestamp: timestamp, status: direction == .outgoing ? status : nil)
                .padding(.top, 3)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .cssTextColor(direction == .incoming ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05) : AxoColor(LegacyColor.whiteAlpha90))
        .background {
            if direction == .incoming { shape.fill(AxoColor.surfaceMessageIncoming) } else { BubbleFill(color: bubbleColor, shape: shape) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: direction == .incoming ? .leading : .trailing)
    }
}

/// `SampleMessageBubbles`
public struct SampleMessageBubbles: View {
    let bubbleColor: BubbleColor
    @State private var frame: CGRect?
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    public init(bubbleColor: BubbleColor) { self.bubbleColor = bubbleColor }

    func message(_ direction: MessageDirection, _ key: String, hoursAgo: Double, status: MessageStatus) -> some View {
        SampleMessage(bubbleColor: bubbleColor, direction: direction, text: i18n(key),
                      timestamp: (fixedNow ?? .now).addingTimeInterval(-hoursAgo * 3600), status: status)
    }

    public var body: some View {
        VStack(spacing: 12) {
            message(.outgoing, "icu:ChatColorPicker__sampleBubble1", hoursAgo: 4, status: .read)
            message(.incoming, "icu:ChatColorPicker__sampleBubble2", hoursAgo: 2, status: .read)
            message(.outgoing, "icu:ChatColorPicker__sampleBubble3", hoursAgo: 0, status: .delivered)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .environment(\.chatColorViewport, frame)
    }
}

public struct ChatColorPicker: View {
    let conversationId: String?
    let customChatColors: [CustomChatColor]
    let selectedPreset: String?
    let selectedCustomColorId: Int?
    let defaultBubbleColor: BubbleColor
    let onSelectPreset: (String) -> Void
    let onSelectCustomColor: (Int) -> Void
    let onAddCustomColor: () -> Void
    let onEditCustomColor: (CustomChatColor) -> Void
    let onDuplicateCustomColor: (CustomChatColor) -> Void
    let onRemoveCustomColor: (CustomChatColor) -> Void
    let onResetChatColor: () -> Void
    let onResetAll: () -> Void
    @State private var menuOpenFor: Int?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(conversationId: String?, customChatColors: [CustomChatColor], selectedPreset: String? = nil, selectedCustomColorId: Int? = nil,
                defaultBubbleColor: BubbleColor = .default, onSelectPreset: @escaping (String) -> Void = { _ in },
                onSelectCustomColor: @escaping (Int) -> Void = { _ in }, onAddCustomColor: @escaping () -> Void = {},
                onEditCustomColor: @escaping (CustomChatColor) -> Void = { _ in }, onDuplicateCustomColor: @escaping (CustomChatColor) -> Void = { _ in },
                onRemoveCustomColor: @escaping (CustomChatColor) -> Void = { _ in }, onResetChatColor: @escaping () -> Void = {},
                onResetAll: @escaping () -> Void = {}) {
        self.conversationId = conversationId
        self.customChatColors = customChatColors
        self.selectedPreset = selectedPreset
        self.selectedCustomColorId = selectedCustomColorId
        self.defaultBubbleColor = defaultBubbleColor
        self.onSelectPreset = onSelectPreset
        self.onSelectCustomColor = onSelectCustomColor
        self.onAddCustomColor = onAddCustomColor
        self.onEditCustomColor = onEditCustomColor
        self.onDuplicateCustomColor = onDuplicateCustomColor
        self.onRemoveCustomColor = onRemoveCustomColor
        self.onResetChatColor = onResetChatColor
        self.onResetAll = onResetAll
    }

    /// `resolveBubbleColorRenderData`
    var resolvedColor: BubbleColor {
        if let selectedPreset { return .preset(selectedPreset) }
        if let id = selectedCustomColorId, let c = customChatColors.first(where: { $0.id == id }) { return c.color }
        return defaultBubbleColor
    }

    /// `.ChatColorPicker__bubble`: a 52px bubble (4px border, 2px padding) of the colour;
    /// selected: a gray-75 (dark: white) border.
    func bubble<Inner: View>(_ fill: BubbleColor?, background: AxoColor? = nil, selected: Bool, focused: Bool = false,
                             @ViewBuilder inner: () -> Inner) -> some View {
        ZStack {
            if let fill {
                BubbleFill(color: fill, shape: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 20, bottomLeading: 20,
                                                                                                     bottomTrailing: 20, topTrailing: 20)))
                    .environment(\.chatColorViewport, nil)
                    .frame(width: 40, height: 40)
            } else if let background {
                Circle().fill(background).frame(width: 40, height: 40)
            }
            inner()
        }
        .frame(width: 52, height: 52)
        // :focus wins over --selected (the first preset takes the initial focus).
        .overlay {
            Circle().strokeBorder(focused ? AxoColor(LegacyColor.ultramarine) : selected ? AxoColor(light: LegacyColor.gray75, dark: LegacyColor.white)
                                  : AxoColor(RGBA(0, 0, 0, 0)), lineWidth: 4)
        }
        .contentShape(Circle())
    }

    var bubbles: some View {
        BubbleGridLayout(side: 52, gap: 24) {
            ForEach(ConversationColors.all, id: \.self) { color in
                SwiftUI.Button { onSelectPreset(color) } label: {
                    bubble(.preset(color), selected: color == selectedPreset, focused: staticRendering && color == ConversationColors.all[0]) { EmptyView() }
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color)
                    .accessibilityAddTraits(color == selectedPreset ? .isSelected : [])
            }
            ForEach(customChatColors) { c in
                let selected = c.id == selectedCustomColorId
                AxoDropdownMenu.Root(isOpen: Binding(get: { menuOpenFor == c.id }, set: { menuOpenFor = $0 && selected ? c.id : nil })) {
                    bubble(c.color, selected: selected) {
                        if selected { SignalIcon("v3/more/more", size: 24, color: AxoColor(LegacyColor.gray05)) }
                    }
                    .onTapGesture { if !selected { onSelectCustomColor(c.id) } }
                    .accessibilityLabel("\(c.id)")
                } items: {
                    AxoDropdownMenu.Item(i18n("icu:ChatColorPicker__context--edit")) { onEditCustomColor(c) }
                    AxoDropdownMenu.Item(i18n("icu:ChatColorPicker__context--duplicate")) { onDuplicateCustomColor(c) }
                    AxoDropdownMenu.Item(i18n("icu:ChatColorPicker__context--delete")) { onRemoveCustomColor(c) }
                }
            }
            SwiftUI.Button(action: onAddCustomColor) {
                bubble(nil, background: AxoColor(LegacyColor.gray05), selected: false) {
                    SignalIcon("v3/plus/plus", size: 24, color: AxoColor(LegacyColor.gray90))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:ChatColorPicker__custom-color--label"))
        }
        .padding(.vertical, 20)
    }

    public var body: some View {
        AxoContainer.Root {
            // mb-4 bg-surface-primary border-[0.5px] border-secondary py-4 curved-2xl
            let card = SuperellipseRect.curved(AxoRadius._2xl)
            SampleMessageBubbles(bubbleColor: resolvedColor)
                .padding(.vertical, 16)
                // Chromium draws the 0.5px border a whole CSS pixel wide here.
                .padding(1)
                .background(card.fill(AxoColor.surfacePrimary))
                .overlay(card.strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
                .padding(.bottom, 16)
            AxoList.Group {
                AxoList.Root { AxoList.Body { bubbles } }
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            if conversationId != nil {
                                AxoClickableItem.Root(label: i18n("icu:ChatColorPicker__reset"), onClick: onResetChatColor)
                            }
                            AxoClickableItem.Root(label: i18n("icu:ChatColorPicker__resetAll"), onClick: onResetAll)
                        }
                    }
                }
            }
        }
    }
}

/// `grid gap-6 grid-template-columns: repeat(auto-fit, 52px) justify-content: center`.
struct BubbleGridLayout: Layout {
    let side: CGFloat
    let gap: CGFloat
    func columns(_ width: CGFloat) -> Int { max(1, Int((width + gap) / (side + gap))) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let n = columns(width), rows = (subviews.count + n - 1) / n
        return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * side + gap * CGFloat(rows - 1))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = min(columns(bounds.width), max(1, subviews.count))
        let used = CGFloat(columns(bounds.width)) * side + gap * CGFloat(columns(bounds.width) - 1)
        let x0 = bounds.minX + (bounds.width - used) / 2
        _ = n
        for (i, s) in subviews.enumerated() {
            let c = i % columns(bounds.width), r = i / columns(bounds.width)
            s.place(at: CGPoint(x: x0 + CGFloat(c) * (side + gap), y: bounds.minY + CGFloat(r) * (side + gap)), proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

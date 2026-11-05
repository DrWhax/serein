// Ports of ts/components/AvatarColorPicker.dom.tsx, AvatarModalButtons.dom.tsx and
// AvatarUploadButton.dom.tsx (stylesheets/components/AvatarEditor.scss), the parts the avatar
// editors share.

import AppKit
import SignalI18n
import SwiftUI

/// `.AvatarEditor__avatar-selector-title`: font-body-1-bold, label-primary, 14px below.
struct AvatarSelectorTitle: View {
    let text: String
    var body: some View {
        CSSText(text, style: LegacyType.body1(weight: 700), color: .labelPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
    }
}

/// `.AvatarEditor__avatars`: a wrapping row of 56px bubbles, 7px apart.
struct AvatarBubbleRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        CSSFlowLayout(spacing: 7, lineSpacing: 7) { content }
    }
}

/// A wrapping flex row (flex-wrap with gap).
struct CSSFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !out[out.count - 1].isEmpty && x + spacing + s.width > width {
                out.append([])
                x = 0
            }
            x += (out[out.count - 1].isEmpty ? 0 : spacing) + s.width
            out[out.count - 1].append((i, s))
        }
        return out
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let ls = lines(subviews, width: width)
        let h = ls.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, ls.count - 1))
        return CGSize(width: proposal.width ?? ls.map { $0.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0, height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            let h = line.map(\.1.height).max() ?? 0
            for (i, s) in line {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + lineSpacing
        }
    }
}

public struct AvatarColorPicker: View {
    let selectedColor: String?
    let onColorSelected: (String) -> Void
    @Environment(\.i18n) var i18n
    public init(selectedColor: String? = nil, onColorSelected: @escaping (String) -> Void = { _ in }) {
        self.selectedColor = selectedColor
        self.onColorSelected = onColorSelected
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AvatarSelectorTitle(text: i18n("icu:AvatarColorPicker--choose"))
            AvatarBubbleRow {
                ForEach(AxoTokens.Avatar.allColorNames, id: \.self) { color in
                    BetterAvatarBubble(color: color, isSelected: selectedColor == color, onSelect: { onColorSelected(color) }) { EmptyView() }
                }
            }
        }
    }
}

/// Cancel / Save. Cancelling with changes asks to discard first.
public struct AvatarModalButtons: View {
    let isInsideDialog: Bool
    let hasChanges: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(isInsideDialog: Bool = false, hasChanges: Bool, onCancel: @escaping () -> Void = {}, onSave: @escaping () -> Void = {}) {
        self.isInsideDialog = isInsideDialog
        self.hasChanges = hasChanges
        self.onCancel = onCancel
        self.onSave = onSave
    }

    func handleCancel() {
        guard hasChanges, let modals else { return onCancel() }
        let id = "avatar-discard"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:ConfirmDiscardDialog--discard")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:discard"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    onCancel()
                }
            }
        }
    }

    public var body: some View {
        if isInsideDialog {
            AxoDialog.Actions {
                AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: handleCancel)
                AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary, disabled: !hasChanges, action: onSave)
            }
        } else {
            // ms-auto flex w-fit max-w-full flex-wrap items-center gap-2 py-2.5
            HStack(spacing: 8) {
                AxoButton.Root(i18n("icu:cancel"), variant: .strongSecondary, size: .lg, width: .grow, action: handleCancel)
                AxoButton.Root(i18n("icu:save"), variant: .strongPrimary, size: .lg, width: .grow, disabled: !hasChanges, action: onSave)
            }
            .fixedSize()
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The "Photo" button: picks a GIF / JPEG / PNG / WebP file. Decoding and scaling the picked
/// file (`processImageFile`) belongs to the media service, so the caller receives its URL.
public struct AvatarUploadButton<Label: View>: View {
    let onChange: (URL) -> Void
    let label: (String) -> Label
    @Environment(\.i18n) var i18n

    public init(onChange: @escaping (URL) -> Void, @ViewBuilder label: @escaping (String) -> Label) {
        self.onChange = onChange
        self.label = label
    }

    public var body: some View {
        SwiftUI.Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.gif, .jpeg, .png, .webP]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { onChange(url) }
        } label: {
            label(i18n("icu:photo"))
        }
        .buttonStyle(.plain)
    }
}

extension AvatarUploadButton where Label == CSSText {
    /// Unstyled (the story's empty className): the page's body text.
    public init(onChange: @escaping (URL) -> Void) {
        self.init(onChange: onChange) { CSSText($0, style: LegacyType.body1(), wrap: .nowrap, color: .labelPrimary) }
    }
}

// Port of ts/components/Toast.dom.tsx (stylesheets/components/Toast.scss): a dark, rounded
// notice (body-2, at most 280px) that closes itself after `timeout` or on click, with an
// optional action on its end.

import SwiftUI

public struct Toast<Content: View>: View {
    public struct Action {
        public var label: String
        public var onClick: () -> Void
        public init(label: String, onClick: @escaping () -> Void) {
            self.label = label
            self.onClick = onClick
        }
    }

    let autoDismissDisabled: Bool
    let disableCloseOnClick: Bool
    let timeout: Duration
    let toastAction: Action?
    let onClose: () -> Void
    let content: Content
    @Environment(\.toastMaxWidth) var maxWidth

    public init(autoDismissDisabled: Bool = false, disableCloseOnClick: Bool = false, timeout: Duration = .milliseconds(8000), toastAction: Action? = nil,
                onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.autoDismissDisabled = autoDismissDisabled
        self.disableCloseOnClick = disableCloseOnClick
        self.timeout = timeout
        self.toastAction = toastAction
        self.onClose = onClose
        self.content = content()
    }

    /// 0 0 4px black/5%, 0 4px 12px black/30%
    static var shadow: [AxoShadowLayer] {
        [AxoShadowLayer(inset: false, x: 0, y: 0, blur: 4, spread: 0, color: RGBA(0, 0, 0, 0.05)),
         AxoShadowLayer(inset: false, x: 0, y: 4, blur: 12, spread: 0, color: RGBA(0, 0, 0, 0.3))]
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        // width: fit-content, max-width 280px
        FitContent(maxWidth: maxWidth) { row }
        .background(shape.fill(AxoColor(LegacyColor.gray75)))
        .clipShape(shape)
        .cssBoxShadow(Self.shadow, in: shape)
        .contentShape(shape)
        .onTapGesture { if !disableCloseOnClick { onClose() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: autoDismissDisabled) {
            guard !autoDismissDisabled else { return }
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { onClose() }
        }
    }

    var row: some View {
        HStack(alignment: .center, spacing: 0) {
            content
                .cssTextColor(AxoColor(LegacyColor.gray05))
                .padding(.vertical, 13).padding(.horizontal, 16)
            if let toastAction {
                Button {
                    toastAction.onClick()
                    onClose()
                } label: {
                    CSSText(toastAction.label, style: LegacyType.body2(weight: 700), wrap: .nowrap, color: AxoColor(LegacyColor.iosBlueTint))
                        .padding(.vertical, 13).padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// CSS `width: fit-content; max-width`: the child at its own width for a proposal capped at
/// `maxWidth`.
struct FitContent: Layout {
    let maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension Toast where Content == CSSText {
    /// A toast of plain text (`font-body-2`).
    public init(_ text: String, autoDismissDisabled: Bool = false, disableCloseOnClick: Bool = false, timeout: Duration = .milliseconds(8000),
                toastAction: Action? = nil, onClose: @escaping () -> Void = {}) {
        self.init(autoDismissDisabled: autoDismissDisabled, disableCloseOnClick: disableCloseOnClick, timeout: timeout, toastAction: toastAction,
                  onClose: onClose) { CSSText(text, style: LegacyType.body2()) }
    }
}

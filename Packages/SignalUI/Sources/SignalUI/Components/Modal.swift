// Port of ts/components/Modal.dom.tsx (Modal, ModalPage, Modal.ButtonFooter) and
// ts/components/ModalHost.dom.tsx, styled by stylesheets/components/Modal.scss and the
// `.module-modal-host__*` rules of stylesheets/_modules.scss.
//
//   ModalHost  — the portal: a black-alpha-40 overlay and a centred 360px width container
//   ModalPage  — one page: header (back button, title, close button, header children),
//                a scrolling body and an optional button footer
//   Modal      — ModalHost + ModalPage (upstream also animates opacity / translateY(48px) in)
//
// The body is a scroll container (the content clipped at offset 0 under axoStaticRendering)
// whose top / bottom 1px borders turn `border-primary` when content is scrolled under them
// (`--scrollVerticalOverflow:not(--scrollAtTop / --scrollAtBottom)`) or with a divider.
// FocusScope's autoFocus focuses the first tabbable control (back, then close); with none,
// the modal itself (tabIndex -1) takes focus and shows Chromium's default focus outline.
// Footer buttons are the caller's: pass `autoFocus: true` to the first when the header has
// no buttons.

import SwiftUI

/// i18n: `icu:back`, `icu:close` (upstream passes `i18n`; these are the English strings).
public struct ModalStrings: Sendable, Hashable {
    public var back: String
    public var close: String
    public init(back: String, close: String) {
        self.back = back
        self.close = close
    }
}

/// `<ModalHost>`: overlay plus the centred width container (max-width 360px, width 95%).
public struct ModalHost<Content: View>: View {
    let onClose: (() -> Void)?
    let content: Content

    public init(onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // .module-modal-host__overlay: $color-black-alpha-40; a click outside closes.
                Rectangle().fill(AxoColor(LegacyColor.blackAlpha40))
                    .contentShape(Rectangle())
                    .onTapGesture { onClose?() }
                ModalCentering {
                    content
                        .frame(width: min(360, (geo.size.width - 40) * 0.95))
                        .environment(\.legacyModalMaxHeight, geo.size.height * 0.89)   // max-height: 89vh
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onExitCommand { onClose?() }
    }
}

/// Centres the width container (flex justify/align center). The modal is a composited
/// layer (react-spring's `transform`), which Chromium snaps to whole CSS pixels.
struct ModalCentering: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height))
            s.place(at: CGPoint(x: bounds.minX + ((bounds.width - size.width) / 2).rounded(), y: bounds.minY + ((bounds.height - size.height) / 2).rounded()),
                    proposal: ProposedViewSize(size))
        }
    }
}

struct LegacyModalMaxHeightKey: EnvironmentKey { static let defaultValue: CGFloat = .infinity }

extension EnvironmentValues {
    var legacyModalMaxHeight: CGFloat {
        get { self[LegacyModalMaxHeightKey.self] }
        set { self[LegacyModalMaxHeightKey.self] = newValue }
    }
}

/// `<Modal>`: a ModalHost with one ModalPage.
public struct Modal<Content: View, Footer: View>: View {
    let page: ModalPage<Content, Footer>

    public init(modalName: String, strings: ModalStrings, title: String? = nil, hasXButton: Bool = false, hasHeaderDivider: Bool = false,
                hasFooterDivider: Bool = false, padded: Bool = true, headerChildren: AnyView? = nil, onBackButtonClick: (() -> Void)? = nil,
                onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        page = ModalPage(modalName: modalName, strings: strings, title: title, hasXButton: hasXButton, hasHeaderDivider: hasHeaderDivider,
                         hasFooterDivider: hasFooterDivider, padded: padded, headerChildren: headerChildren,
                         onBackButtonClick: onBackButtonClick, onClose: onClose, content: content, footer: footer)
    }

    public var body: some View {
        ModalHost(onClose: page.onClose) { page }
    }
}

extension Modal where Footer == EmptyView {
    public init(modalName: String, strings: ModalStrings, title: String? = nil, hasXButton: Bool = false, hasHeaderDivider: Bool = false,
                hasFooterDivider: Bool = false, padded: Bool = true, headerChildren: AnyView? = nil, onBackButtonClick: (() -> Void)? = nil,
                onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        page = ModalPage(modalName: modalName, strings: strings, title: title, hasXButton: hasXButton, hasHeaderDivider: hasHeaderDivider,
                         hasFooterDivider: hasFooterDivider, padded: padded, headerChildren: headerChildren,
                         onBackButtonClick: onBackButtonClick, onClose: onClose, content: content)
    }
}

/// `<ModalPage>`: `.module-Modal` without the host and the open/close animation.
public struct ModalPage<Content: View, Footer: View>: View {
    let modalName: String
    let strings: ModalStrings
    let title: String?
    let hasXButton: Bool
    let hasHeaderDivider: Bool
    let hasFooterDivider: Bool
    let padded: Bool
    let headerChildren: AnyView?
    let onBackButtonClick: (() -> Void)?
    let onClose: () -> Void
    let hasFooter: Bool
    let content: Content
    let footer: Footer
    /// The content moves the initial focus to one of its controls (a search input focused in
    /// an effect), so the header buttons do not keep it.
    var contentTakesFocus = false
    @Environment(\.legacyModalMaxHeight) var maxHeight
    @FocusState private var selfFocused: Bool
    @State private var autoFocusConsumed = false

    public init(modalName: String, strings: ModalStrings, title: String? = nil, hasXButton: Bool = false, hasHeaderDivider: Bool = false,
                hasFooterDivider: Bool = false, padded: Bool = true, headerChildren: AnyView? = nil, onBackButtonClick: (() -> Void)? = nil,
                onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.modalName = modalName
        self.strings = strings
        self.title = title
        self.hasXButton = hasXButton
        self.hasHeaderDivider = hasHeaderDivider
        self.hasFooterDivider = hasFooterDivider
        self.padded = padded
        self.headerChildren = headerChildren
        self.onBackButtonClick = onBackButtonClick
        self.onClose = onClose
        self.hasFooter = Footer.self != EmptyView.self
        self.content = content()
        self.footer = footer()
    }

    var hasHeader: Bool { hasXButton || title != nil || headerChildren != nil || onBackButtonClick != nil }
    /// `contentTakesFocus`
    public func contentTakesFocus(_ value: Bool = true) -> ModalPage {
        var copy = self
        copy.contentTakesFocus = value
        return copy
    }

    /// FocusScope autoFocus: nothing tabbable in the header → the modal itself is focused.
    var focusesSelf: Bool { onBackButtonClick == nil && !hasXButton && !hasFooter }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        ModalColumn(maxHeight: maxHeight) {
            if hasHeader { header } else { Color.clear.frame(height: 0) }
            ModalBody(hasHeader: hasHeader, hasFooter: hasFooter, headerDivider: hasHeaderDivider, footerDivider: hasFooterDivider,
                      padded: padded) { content }
            if hasFooter { ModalButtonFooter { footer } } else { Color.clear.frame(height: 0) }
        }
        .cssTextColor(.labelPrimary)
        .background(shape.fill(AxoColor.materialDialog))   // backdrop-filter: blur(24px) over a uniform overlay
        .clipShape(shape)
        .cssBoxShadow(Self.popperShadow, in: shape)
        .overlay { if focusesSelf && !autoFocusConsumed { ChromiumFocusOutline(shape: shape) } }
        .focusable(focusesSelf)
        .focusEffectDisabled()
        .focused($selfFocused)
        .onChange(of: selfFocused) { _, now in if !now { autoFocusConsumed = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "")
        .accessibilityIdentifier(modalName)
        .accessibilityAddTraits(.isModal)
    }

    /// `@include mixins.popper-shadow`
    static var popperShadow: [AxoShadowLayer] {
        [AxoShadowLayer(inset: false, x: 0, y: 8, blur: 20, spread: 0, color: RGBA(0, 0, 0, 0.3)),
         AxoShadowLayer(inset: false, x: 0, y: 0, blur: 8, spread: 0, color: RGBA(0, 0, 0, 0.05))]
    }

    /// `.module-Modal__headerTitle` (flex, items-center, space-between, padding 16px 16px 1em) + header children.
    var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                if let onBackButtonClick {
                    ModalIconButton(icon: .chevronLeft, label: strings.back, autoFocus: !contentTakesFocus, flipsForRTL: true, action: onBackButtonClick)
                }
                if let title {
                    CSSBlockText(title, style: LegacyType.body1(weight: 600), alignment: onBackButtonClick != nil ? .center : .start)
                        .frame(maxWidth: .infinity, alignment: onBackButtonClick != nil ? .center : .leading)
                        .accessibilityAddTraits(.isHeader)
                } else if hasXButton {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
                if hasXButton {
                    ModalIconButton(icon: .x, label: strings.close, autoFocus: onBackButtonClick == nil && !contentTakesFocus, flipsForRTL: false,
                                    action: onClose)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
            if let headerChildren { headerChildren }
        }
    }
}

extension ModalPage where Footer == EmptyView {
    public init(modalName: String, strings: ModalStrings, title: String? = nil, hasXButton: Bool = false, hasHeaderDivider: Bool = false,
                hasFooterDivider: Bool = false, padded: Bool = true, headerChildren: AnyView? = nil, onBackButtonClick: (() -> Void)? = nil,
                onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.init(modalName: modalName, strings: strings, title: title, hasXButton: hasXButton, hasHeaderDivider: hasHeaderDivider,
                  hasFooterDivider: hasFooterDivider, padded: padded, headerChildren: headerChildren, onBackButtonClick: onBackButtonClick,
                  onClose: onClose, content: content, footer: { EmptyView() })
    }
}

/// Chromium's default `outline: auto` focus ring (UA style, not a design token): 2px of
/// -webkit-focus-ring-color centred on the border edge with a 1px white halo outside.
struct ChromiumFocusOutline<S: InsettableShape>: View {
    /// Chromium's focus ring colours (light / dark colour scheme).
    static var ringColor: AxoColor { AxoColor(light: RGBA(hex: 0x005FCC), dark: RGBA(hex: 0x99C8FF)) }
    static var haloColor: AxoColor { AxoColor(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x101010)) }
    let shape: S
    var body: some View {
        ZStack {
            shape.inset(by: -2).strokeBorder(Self.haloColor, lineWidth: 1)
            shape.inset(by: -1).strokeBorder(Self.ringColor, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// `.module-Modal__back-button` / `__close-button`: a 20×20 button whose ::before is the
/// icon in label-secondary.
struct ModalIconButton: View {
    let icon: LegacyIcon
    let label: String
    let autoFocus: Bool
    let flipsForRTL: Bool
    let action: () -> Void
    private var focus = AxoFocusState()
    @Environment(\.layoutDirection) var direction

    init(icon: LegacyIcon, label: String, autoFocus: Bool, flipsForRTL: Bool, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.autoFocus = autoFocus
        self.flipsForRTL = flipsForRTL
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        SwiftUI.Button(action: action) {
            LegacyIcon.Mask(icon, color: .labelSecondary)
                .scaleEffect(x: flipsForRTL && direction == .rightToLeft ? -1 : 1)
                .frame(width: 20, height: 20)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .axoFocusRing(focus.visible(autoFocus: autoFocus), in: shape)
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
        .accessibilityLabel(label)
    }
}

/// `.module-Modal` is a flex column with max-height: 89vh: header and footer keep their
/// height and the body (subview 1) gets the rest, down to scrolling.
struct ModalColumn: Layout {
    let maxHeight: CGFloat

    func heights(_ width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let natural = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let fixed = natural[0] + natural[2]
        return [natural[0], max(0, min(natural[1], maxHeight - fixed)), natural[2]]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights(width, subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (s, h) in zip(subviews, heights(bounds.width, subviews)) {
            s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}

/// `.module-Modal__body` (font-body-1, scroll container) with its `__body_inner`.
struct ModalBody<Content: View>: View {
    let hasHeader: Bool
    let hasFooter: Bool
    let headerDivider: Bool
    let footerDivider: Bool
    let padded: Bool
    let content: Content
    @Environment(\.axoStaticRendering) var isStatic
    @State private var offset: CGFloat = 0

    init(hasHeader: Bool, hasFooter: Bool, headerDivider: Bool, footerDivider: Bool, padded: Bool, @ViewBuilder content: () -> Content) {
        self.hasHeader = hasHeader
        self.hasFooter = hasFooter
        self.headerDivider = headerDivider
        self.footerDivider = footerDivider
        self.padded = padded
        self.content = content()
    }

    var inner: some View {
        // --padded: padding 16px (top 0 with a header)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: padded && !hasHeader ? 16 : 0, leading: padded ? 16 : 0, bottom: padded ? 16 : 0, trailing: padded ? 16 : 0))
    }

    var body: some View {
        ModalBodyLayout(topBorder: hasHeader, bottomBorder: hasHeader || hasFooter, offset: isStatic ? 0 : offset,
                        alwaysTop: hasHeader && headerDivider, alwaysBottom: hasFooter && footerDivider, scrollTop: hasHeader, scrollBottom: hasFooter) {
            inner.hidden().accessibilityHidden(true)                 // measuring copy
            Group {
                if isStatic {
                    AxoDialog.TopAligned { inner }.clipShape(Rectangle())
                } else {
                    ScrollView { inner }
                        .scrollIndicators(.automatic)
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
                }
            }
            Rectangle().fill(AxoColor.borderPrimary)
            Rectangle().fill(AxoColor.borderPrimary)
        }
        .cssTextColor(.labelPrimary)
    }
}

/// Places the scroll container between the body's 1px top / bottom borders; a border is
/// painted (subviews 2, 3) when its divider is on, or when content is scrolled under it.
struct ModalBodyLayout: Layout {
    let topBorder: Bool
    let bottomBorder: Bool
    let offset: CGFloat
    let alwaysTop: Bool
    let alwaysBottom: Bool
    let scrollTop: Bool
    let scrollBottom: Bool

    var borders: CGFloat { (topBorder ? 1 : 0) + (bottomBorder ? 1 : 0) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: proposal.height ?? (natural.height + borders))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let top: CGFloat = topBorder ? 1 : 0
        let available = max(0, bounds.height - borders)
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        subviews[0].place(at: CGPoint(x: bounds.minX - 100_000, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), proposal: ProposedViewSize(width: bounds.width, height: available))
        let overflow = natural > available + 0.5
        let atTop = offset <= 0
        let atBottom = offset + available >= natural - 0.5
        let showTop = topBorder && (alwaysTop || (scrollTop && overflow && !atTop))
        let showBottom = bottomBorder && (alwaysBottom || (scrollBottom && overflow && !atBottom))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: showTop ? bounds.width : 0, height: showTop ? 1 : 0))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - 1),
                          proposal: ProposedViewSize(width: showBottom ? bounds.width : 0, height: showBottom ? 1 : 0))
    }
}

/// `<Modal.ButtonFooter>`: flex row wrap, justify-end, items-center, gap 8px, padding 1em 16px 16px;
/// buttons after the first get margin-inline-start 4px. Once the buttons wrap (useHasWrapped)
/// it becomes `--one-button-per-line`: a column with the buttons aligned to the end.
public struct ModalButtonFooter<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        ModalButtonFooterLayout { content }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    }
}

struct ModalButtonFooterLayout: Layout {
    static let gap: CGFloat = 8
    static let margin: CGFloat = 4

    func wraps(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        let total = subviews.enumerated().map { i, s in s.sizeThatFits(.unspecified).width + (i > 0 ? Self.margin : 0) }.reduce(0, +)
            + Self.gap * CGFloat(max(0, subviews.count - 1))
        return total > width + 0.01
    }

    func columnSizes(_ width: CGFloat, _ subviews: Subviews) -> [CGSize] {
        subviews.enumerated().map { i, s in
            let available = width - (i > 0 ? Self.margin : 0)
            let natural = s.sizeThatFits(.unspecified)
            return natural.width <= available ? natural : s.sizeThatFits(ProposedViewSize(width: available, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        if !wraps(width, subviews) {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let w = sizes.map(\.width).reduce(0, +) + (Self.gap + Self.margin) * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: proposal.width ?? w, height: sizes.map(\.height).max() ?? 0)
        }
        let sizes = columnSizes(width, subviews)
        return CGSize(width: width, height: sizes.map(\.height).reduce(0, +) + Self.gap * CGFloat(max(0, sizes.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if !wraps(bounds.width, subviews) {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let lineHeight = sizes.map(\.height).max() ?? 0
            var x = bounds.maxX
            for (s, size) in zip(subviews, sizes).reversed() {
                x -= size.width
                s.place(at: CGPoint(x: x, y: bounds.minY + (lineHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x -= Self.gap + Self.margin
            }
            return
        }
        var y = bounds.minY
        for (s, size) in zip(subviews, columnSizes(bounds.width, subviews)) {
            s.place(at: CGPoint(x: bounds.maxX - size.width, y: y), proposal: ProposedViewSize(size))
            y += size.height + Self.gap
        }
    }
}

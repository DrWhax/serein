// Port of ts/components/ContactPills.dom.tsx + ContactPill.dom.tsx and their stylesheets
// (stylesheets/components/ContactPills.scss, ContactPill.scss): removable contact chips in a
// wrapping, vertically scrolling box (max-height 88px) that scrolls to the bottom when a
// pill is added.
//
// The pill's name is upstream's <ContactName preferFirstName> (UserText, emoji-aware), drawn
// here as plain text until ContactName is ported.

import SwiftUI

public struct ContactPills<Content: View>: View {
    let content: Content
    let count: Int
    @Environment(\.axoStaticRendering) var isStatic

    /// `count`: the number of pills (upstream counts its children to scroll to new ones).
    public init(count: Int, @ViewBuilder content: () -> Content) {
        self.count = count
        self.content = content()
    }

    /// display: flex; flex-wrap: wrap; gap: 8px 12px; padding: 4px 16px
    var pills: some View {
        CSSFlex(.row, wrap: true, gap: 12, crossGap: 8, align: .center) { content }
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.contactPillMaxWidthInset, 15)
    }

    public var body: some View {
        AxoDialog.HeightLimited(maxHeight: 88) {
            pills.hidden().accessibilityHidden(true)
            if isStatic {
                // Mounting with pills counts as adding them: scrolled to the bottom.
                BottomAligned { pills }.clipShape(Rectangle())
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            pills
                            Color.clear.frame(height: 0).id("bottom")
                        }
                    }
                    .onChange(of: count) { old, new in
                        if new > old { withAnimation(.default) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                    // usePreviousDeprecated(0, …): the first render counts as adding every pill.
                    .onAppear { if count > 0 { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .padding(.bottom, 10)                     // margin-bottom: 10px
    }
}

/// Takes the proposed size; places its child's bottom at the bottom (scrolled to the end).
struct BottomAligned: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? child.width, height: proposal.height ?? child.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            s.place(at: CGPoint(x: bounds.minX, y: bounds.minY + min(0, bounds.height - h)), proposal: ProposedViewSize(width: bounds.width, height: h))
        }
    }
}

struct ContactPillMaxWidthInsetKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// `.module-ContactPills .module-ContactPill { max-width: calc(100% - 15px) }`
    var contactPillMaxWidthInset: CGFloat? {
        get { self[ContactPillMaxWidthInsetKey.self] }
        set { self[ContactPillMaxWidthInsetKey.self] = newValue }
    }
}

/// `<ContactPill>`: a 20px avatar, the (first) name and a remove button.
public struct ContactPill: View {
    let id: String
    let title: String
    let firstName: String?
    let color: String
    let avatarStrings: AvatarStrings
    /// i18n: `icu:ContactPill--remove`
    let removeLabel: String
    let image: AnyView?
    let hasAvatar: Bool
    let onClickRemove: (String) -> Void
    private var focus = AxoFocusState()
    @Environment(\.contactPillMaxWidthInset) var maxWidthInset

    public init(id: String, title: String, firstName: String? = nil, color: String = "A200", image: AnyView? = nil, hasAvatar: Bool = false,
                avatarStrings: AvatarStrings, removeLabel: String, onClickRemove: @escaping (String) -> Void) {
        self.id = id
        self.title = title
        self.firstName = firstName
        self.color = color
        self.image = image
        self.hasAvatar = hasAvatar
        self.avatarStrings = avatarStrings
        self.removeLabel = removeLabel
        self.onClickRemove = onClickRemove
    }

    public var body: some View {
        let focused = focus.visible(autoFocus: false)
        let shape = RoundedRectangle(cornerRadius: 6)
        // inline-flex, items-center, overflow hidden, padding 4px 8px
        CSSFlex(.row, align: .center) {
            Avatar(strings: avatarStrings, title: title, size: 20, conversationType: .direct, color: color, image: image, hasAvatar: hasAvatar)
                .flexItem(shrink: 0)
            // .module-ContactPill__contact-name: font-body-2, padding 0 6px, ellipsis
            CSSText(firstName.flatMap { $0.isEmpty ? nil : $0 } ?? title, style: LegacyType.body2(), wrap: .truncate)
                .padding(.horizontal, 6)
                .flexItem(minMain: 0)
            SwiftUI.Button { onClickRemove(id) } label: {
                LegacyIcon.Mask(.xCompactLight, color: focused ? AxoColor(light: LegacyColor.white, dark: LegacyColor.gray90)
                                : AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused(focus.$focused)
            .accessibilityLabel(removeLabel)
            .help(removeLabel)
            .flexItem(shrink: 0)
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .cssTextColor(focused ? AxoColor(light: LegacyColor.white, dark: LegacyColor.gray90) : AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
        .background(shape.fill(focused ? AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25)
                               : AxoColor(light: LegacyColor.blackAlpha08, dark: LegacyColor.whiteAlpha12)))
        .clipShape(shape)
        .axoFocusRing(focused, in: shape)       // focus-visible-within
        .flexItem(maxMainInset: maxWidthInset)
    }
}


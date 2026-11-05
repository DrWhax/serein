// Megaphones above the chat list: Megaphone (ts/components/Megaphone.dom.tsx) with its
// PinReminderMegaphone and RemoteMegaphone uses, and the legacy-styled UsernameMegaphone
// (stylesheets/components/UsernameMegaphone.scss).

import SignalI18n
import SwiftUI

public struct Megaphone: View {
    let title: String
    let body_: String
    let image: RGBAImage?
    let isFullSize: Bool
    let primaryCtaText: String?
    let secondaryCtaText: String?
    let onClickNarrowMegaphone: () -> Void
    let onClickPrimaryCta: (() -> Void)?
    let onClickSecondaryCta: (() -> Void)?
    @Environment(\.i18n) var i18n

    public init(title: String, body: String, image: RGBAImage?, isFullSize: Bool, primaryCtaText: String?, secondaryCtaText: String?,
                onClickNarrowMegaphone: @escaping () -> Void = {}, onClickPrimaryCta: (() -> Void)?, onClickSecondaryCta: (() -> Void)?) {
        self.title = title
        self.body_ = body
        self.image = image
        self.isFullSize = isFullSize
        self.primaryCtaText = primaryCtaText
        self.secondaryCtaText = secondaryCtaText
        self.onClickNarrowMegaphone = onClickNarrowMegaphone
        self.onClickPrimaryCta = onClickPrimaryCta
        self.onClickSecondaryCta = onClickSecondaryCta
    }

    /// `max-w-[500px] curved-3xl p-3 bg-material-primary dark:bg-material-tertiary shadow-elevation-1`
    func wrapper(_ content: some View) -> some View {
        let shape = SuperellipseRect.curved(24)
        return content
            .padding(12)
            .background(shape.fill(AxoColor(light: AxoColor.materialPrimary.light, dark: AxoColor.materialTertiary.dark)))
            .axoShadow(.shadowElevation1, in: shape)
    }

    @ViewBuilder func imageView(size: CGFloat) -> some View {
        if let image { PixelImage(image, fit: .cover).frame(width: size, height: size) } else { Color.clear.frame(width: size, height: size) }
    }

    public var body: some View {
        if isFullSize {
            wrapper(VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    imageView(size: 56)
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(title, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 13, lineHeight: 18, letterSpacing: -0.039),
                                color: .labelPrimary)
                            .padding(.top, 2)
                        CSSText(body_, type: .bodySmall, color: .labelSecondary).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // mt-3 flex justify-end > flex flex-wrap-reverse gap-1.5
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CSSShrinkToFit { CSSFlex(.row, wrap: true, gap: 6, reverseLines: true) {
                        if let onClickSecondaryCta, let secondaryCtaText {
                            AxoButton.Root(secondaryCtaText, variant: .strongSecondary, size: .md, width: .grow, action: onClickSecondaryCta)
                                .flexItem(grow: 1)
                        }
                        if let onClickPrimaryCta, let primaryCtaText {
                            AxoButton.Root(primaryCtaText, variant: .strongPrimary, size: .md, width: .grow, action: onClickPrimaryCta)
                                .flexItem(grow: 1)
                        }
                    } }
                }
                .padding(.top, 12)
            })
            .frame(maxWidth: 500, alignment: .leading)
            .accessibilityElement(children: .contain)
        } else {
            Tooltip(direction: i18n.direction == .rightToLeft ? .left : .right) {
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(title, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 13, lineHeight: 18, letterSpacing: -0.039))
                        .padding(.top, 4)
                    CSSText(body_, type: .bodyMedium).padding(.top, 4).padding(.bottom, 8)
                }
                .cssTextColor(.labelPrimary)
            } trigger: {
                SwiftUI.Button(action: onClickNarrowMegaphone) {
                    wrapper(imageView(size: 48).frame(width: 52, height: 52))    // size-[76px] with p-3; the image m-auto
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:Megaphone__ExpandNarrowSidebar"))
            }
        }
    }
}

public struct PinReminderMegaphone: View {
    let isFullSize: Bool
    let onClickNarrowMegaphone: () -> Void
    let onDismiss: () -> Void
    let onShowModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(isFullSize: Bool, onClickNarrowMegaphone: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {},
                onShowModal: @escaping () -> Void = {}) {
        self.isFullSize = isFullSize
        self.onClickNarrowMegaphone = onClickNarrowMegaphone
        self.onDismiss = onDismiss
        self.onShowModal = onShowModal
    }

    public var body: some View {
        Megaphone(title: i18n("icu:PinReminderMegaphone__title"), body: i18n("icu:PinReminderMegaphone__body"),
                  image: BundledImage.named("pin-reminder"), isFullSize: isFullSize,
                  primaryCtaText: i18n("icu:PinReminderMegaphone__verify"), secondaryCtaText: i18n("icu:PinReminderMegaphone__not-now"),
                  onClickNarrowMegaphone: onClickNarrowMegaphone, onClickPrimaryCta: onShowModal, onClickSecondaryCta: onDismiss)
    }
}

/// A server-defined megaphone (title, body, image, up to two call-to-action ids).
public struct RemoteMegaphone: View {
    let remoteMegaphoneId: String
    let title: String
    let body_: String
    let image: RGBAImage?
    let primaryCtaId: String?
    let secondaryCtaId: String?
    let primaryCtaText: String?
    let secondaryCtaText: String?
    let isFullSize: Bool
    let onClickNarrowMegaphone: () -> Void
    let onInteractWithMegaphone: (String, String) -> Void

    public init(remoteMegaphoneId: String, title: String, body: String, image: RGBAImage?, primaryCtaId: String?, secondaryCtaId: String?,
                primaryCtaText: String?, secondaryCtaText: String?, isFullSize: Bool, onClickNarrowMegaphone: @escaping () -> Void = {},
                onInteractWithMegaphone: @escaping (String, String) -> Void = { _, _ in }) {
        self.remoteMegaphoneId = remoteMegaphoneId
        self.title = title
        self.body_ = body
        self.image = image
        self.primaryCtaId = primaryCtaId
        self.secondaryCtaId = secondaryCtaId
        self.primaryCtaText = primaryCtaText
        self.secondaryCtaText = secondaryCtaText
        self.isFullSize = isFullSize
        self.onClickNarrowMegaphone = onClickNarrowMegaphone
        self.onInteractWithMegaphone = onInteractWithMegaphone
    }

    public var body: some View {
        Megaphone(title: title, body: body_, image: image, isFullSize: isFullSize, primaryCtaText: primaryCtaText, secondaryCtaText: secondaryCtaText,
                  onClickNarrowMegaphone: onClickNarrowMegaphone,
                  onClickPrimaryCta: primaryCtaId.map { id in { onInteractWithMegaphone(remoteMegaphoneId, id) } },
                  onClickSecondaryCta: secondaryCtaId.map { id in { onInteractWithMegaphone(remoteMegaphoneId, id) } })
    }
}

public struct UsernameMegaphone: View {
    let onLearnMore: () -> Void
    let onDismiss: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint

    public init(onLearnMore: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        self.onLearnMore = onLearnMore
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if breakpoint != .narrow {    // .NavSidebar--narrow & { display: none }
            let shape = RoundedRectangle(cornerRadius: 10)
            let button = LegacyButton.Overrides(fontWeight: 600, paddingBlock: 5, background: AxoColor(RGBA(0, 0, 0, 0)))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let icon = BundledImage.named(scheme == .dark ? "usernames_40_color_dark" : "usernames_40_color") {
                            PixelImage(icon, fit: .cover)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .padding(.bottom, 2)
                    .padding(.leading, 8)
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(i18n("icu:UsernameMegaphone__title"), style: { var s = LegacyType.body2(weight: 600); s.lineHeight = 20; return s }())
                        CSSText(i18n("icu:UsernameMegaphone__body"), style: LegacyType.body2(),
                                color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                    }
                    .padding(.trailing, 8)
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    LegacyButton(i18n("icu:UsernameMegaphone__dismiss"), size: .small, variant: .secondaryAffirmative, overrides: button, action: onDismiss)
                    LegacyButton(i18n("icu:UsernameMegaphone__learn-more"), size: .small, variant: .secondaryAffirmative, overrides: button,
                                 action: onLearnMore)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .padding(1)
            .background(shape.fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75)))
            .overlay { shape.strokeBorder(AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray60), lineWidth: 1) }
            .cssBoxShadow([AxoShadowLayer(inset: false, x: 0, y: 4, blur: 8, spread: 0, color: RGBA(0, 0, 0, 0.08))], in: shape)
            .cssTextColor(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
        }
    }
}

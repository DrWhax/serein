// Port of ts/components/conversation/StagedLinkPreview.dom.tsx (+ stylesheets/components/
// StagedLinkPreview.scss and `.CompositionInput__link-preview`): the link preview being
// composed. "Loading Preview…" until the domain is known; then the 72px thumbnail (a link
// icon on white without an image, the call-link avatar for call links), the title, the
// description and "domain • date" (or just the domain), and a close button. In the composer
// it is a gray-02 card with the thumbnail on the trailing side; sticker packs get their own
// rounded surface with a 64px image and a strong-secondary close icon button.

import SignalI18n
import SwiftUI

public struct StagedLinkPreview: View {
    /// Where it is shown: on its own, or in the composition input (`CompositionInput__link-preview`).
    public enum Placement: Sendable { case standalone, compositionInput }

    let preview: LinkPreview
    let image: MessageAttachment?
    let isStickerPack: Bool
    let imageSize: CGFloat?
    let placement: Placement
    let onClose: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(preview: LinkPreview, image: MessageAttachment? = nil, isStickerPack: Bool = false, imageSize: CGFloat? = nil,
                placement: Placement = .standalone, onClose: (() -> Void)? = nil) {
        self.preview = preview
        self.image = image
        self.isStickerPack = isStickerPack
        self.imageSize = imageSize
        self.placement = placement
        self.onClose = onClose
    }

    var isLoaded: Bool { !(preview.domain ?? "").isEmpty }
    var inComposer: Bool { placement == .compositionInput }

    /// `moment(date).format('ll')`
    func dateText(_ ms: Double) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: i18n.locale), timeZone: timeZone)
        style.calendar = Calendar(identifier: .gregorian)
        return Date(timeIntervalSince1970: ms / 1000).formatted(style)
    }

    static var footerColor: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }

    public var body: some View {
        if isStickerPack { stickerPack } else { regular }
    }

    // MARK: Regular

    var regular: some View {
        // align-items: stretch (the content column from the top); centred while loading.
        HStack(alignment: isLoaded ? .top : .center, spacing: 0) {
            if inComposer {
                // row-reverse, space-between: content first in reading order, thumbnail at the end.
                if isLoaded { content.padding(.vertical, 8).padding(.leading, 12) }
                Spacer(minLength: 0)
                thumbnail
            } else {
                thumbnail
                if isLoaded { content.padding(.trailing, 20) }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: inComposer ? 74 : 65)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if inComposer { RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray80)) } }
        .clipShape(RoundedRectangle(cornerRadius: inComposer ? 8 : 0))
        .overlay(alignment: .topTrailing) { if let onClose { closeButton(onClose) } }
        .padding(inComposer ? 6 : 0)
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder func closeButton(_ action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            if inComposer {
                SignalIcon("v3/x/x", size: 16, color: AxoColor(light: LegacyColor.blackAlpha50, dark: LegacyColor.whiteAlpha55), mask: true)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(AxoColor(light: RGBA(LegacyColor.gray05.r, LegacyColor.gray05.g, LegacyColor.gray05.b, 0.8),
                                                       dark: RGBA(LegacyColor.gray75.r, LegacyColor.gray75.g, LegacyColor.gray75.b, 0.8))))
            } else {
                SignalIcon("v3/x/x", size: 16, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25), mask: true)
            }
        }
        .buttonStyle(.plain)
        .padding(inComposer ? 6 : 0)
        .accessibilityLabel(i18n("icu:close"))
    }

    @ViewBuilder var thumbnail: some View {
        if !isLoaded {
            CSSText(i18n("icu:loadingPreview"), style: LegacyType.body1(), alignment: .center, color: Self.footerColor)
                .frame(maxWidth: .infinity)
        } else if preview.isCallLink {
            Avatar(strings: AvatarStrings(i18n: i18n), title: preview.title ?? i18n("icu:calling__call-link-default-title"), size: 64,
                   conversationType: .callLink, color: callLinkColor(callLinkKey(preview.url)))
                .padding(4)
        } else if let image, image.isImage {
            let size = imageSize ?? 72
            ConversationImage(attachment: image, url: image.image, width: size, height: size,
                              corners: .init(topLeft: .tiny, topRight: .tiny, bottomLeft: .tiny, bottomRight: .tiny))
                .padding(inComposer ? .leading : .trailing, 8)
        } else {
            // __no-image: a black 44px link icon on a white 74px rounded square
            SignalIcon("v3/link/link", size: 44, color: AxoColor(LegacyColor.black), mask: true)
                .frame(width: 74, height: 74)
                .background(RoundedRectangle(cornerRadius: 14).fill(AxoColor(LegacyColor.white)))
                .padding(.trailing, inComposer ? 0 : 32)
        }
    }

    @ViewBuilder var content: some View {
        let title = preview.title ?? "", description = preview.description ?? ""
        let titleStyle = LegacyType.body1(weight: 600)
        let titleColor = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
        if title.isEmpty && description.isEmpty {
            // --only-url: the domain centred in the row's height
            CSSText(preview.domain ?? "", style: titleStyle, wrap: .clamp(1), color: titleColor)
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CSSText(title, style: titleStyle, wrap: .clamp(1), color: titleColor)
                if !description.isEmpty {
                    CSSText(unescapeHTML(description), style: LegacyType.body1(), wrap: .clamp(1))
                }
                footer
            }
        }
    }

    /// `domain • date`: the bullet at half the size with 0.2rem on each side.
    var footer: some View {
        let style = LegacyType.body2()
        return HStack(alignment: .center, spacing: 0) {
            CSSText((preview.domain ?? "").lowercased(), style: style, wrap: .nowrap, color: Self.footerColor)
            if isLinkPreviewDateValid(preview.date, now: fixedNow ?? .now), let ms = preview.date {
                HStack(alignment: .center, spacing: 0) {
                    CSSText("•", style: { var s = style; s.size /= 2; return s }(), wrap: .nowrap, color: Self.footerColor)
                        .padding(.horizontal, 3.2)
                    CSSText(dateText(ms), style: style, wrap: .nowrap, color: Self.footerColor)
                }
            }
        }
    }

    // MARK: Sticker pack

    var stickerPack: some View {
        HStack(alignment: .top, spacing: 0) {
            if isLoaded, let image, image.isImage {
                // __icon-container: margin-inline-end 8px
                ConversationImage(attachment: image, url: image.image, width: 64, height: 64,
                                  corners: .init(topLeft: .tiny, topRight: .tiny, bottomLeft: .tiny, bottomRight: .tiny))
                    .padding(.trailing, 8)
            } else {
                thumbnail
            }
            if isLoaded {
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(preview.title ?? "", type: AxoType.bodyMedium.weight(600), color: .labelPrimary).padding(.top, 4).padding(.bottom, 2)
                    if let d = preview.description, !d.isEmpty {
                        CSSText(unescapeHTML(d), type: .bodyMedium, color: .labelPrimary).padding(.bottom, 2)
                    }
                    CSSText(preview.domain ?? "", type: .bodySmall, color: .labelSecondary)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onClose {
                AxoIconButton.Root(label: i18n("icu:close"), tooltip: false, variant: .strongSecondary, size: .sm, symbol: "x", action: onClose)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(AxoColor.surfacePrimary))
        .padding(6)
    }
}

/// lodash `unescape`: the five HTML entities.
func unescapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
}

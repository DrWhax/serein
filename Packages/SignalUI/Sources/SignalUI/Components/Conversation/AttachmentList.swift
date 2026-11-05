// Ports of ts/components/conversation/AttachmentList.dom.tsx, StagedGenericAttachment.dom.tsx
// and StagedPlaceholderAttachment.dom.tsx (+ `.module-attachments*`, `.module-staged-*` in
// stylesheets/_modules.scss): the composer's staged attachments. A rail (12px in, 142px tall,
// scrolling sideways) of 120px tiles: images and videos as tiny-curved Images with a close
// button (videos with the play icon; editable images show the edit icon on hover), other
// files as generic tiles, and "+" to add more when every attachment is visual. With more than
// one attachment, a 24px header holds the close-all button.

import SignalI18n
import SwiftUI

/// `StagedGenericAttachment`: a 120px gray tile with the file thumbnail, the name (caption,
/// two lines, centred) and a 16px close button 4px from the top corner.
public struct StagedGenericAttachment: View {
    let attachment: MessageAttachment
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(attachment: MessageAttachment, onClose: @escaping () -> Void = {}) {
        self.attachment = attachment
        self.onClose = onClose
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        VStack(spacing: 5) {
            FileThumbnail(contentType: attachment.contentType, fileName: attachment.fileName)
            if let name = attachment.fileName {
                CSSText(name, style: LegacyType.caption(), wrap: .clamp(2), alignment: .center)
            }
        }
        .padding(7)
        .frame(width: 120, height: 120)
        .cssTextColor(AxoColor(light: LegacyColor.black, dark: LegacyColor.gray02))
        .background(shape.fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)))
        .overlay(shape.strokeBorder(AxoColor(light: LegacyColor.blackAlpha20, dark: LegacyColor.gray45), lineWidth: 1))   // inset 1px shadow
        .overlay(alignment: .topTrailing) {
            SwiftUI.Button(action: onClose) {
                SignalIcon("v3/x/x-compact", size: 16, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray45), mask: true)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:close"))
            .padding(4)
        }
    }
}

/// `StagedPlaceholderAttachment`: a 120px bordered tile (1px gray-25 / gray-60, 1px margin)
/// with a 28px plus; gray-05 (gray-75) on hover.
public struct StagedPlaceholderAttachment: View {
    let onClick: () -> Void
    @State private var hovered = false
    @Environment(\.i18n) var i18n

    public init(onClick: @escaping () -> Void) { self.onClick = onClick }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        SwiftUI.Button(action: onClick) {
            SignalIcon("v3/plus/plus-light", size: 28, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray60), mask: true)
                .frame(width: 120, height: 120)
                .background(shape.fill(hovered ? AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75) : AxoColor(RGBA(0, 0, 0, 0))))
                .overlay(shape.strokeBorder(AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(1)
        .accessibilityLabel(i18n("icu:addImageOrVideoattachment"))
    }
}

public struct AttachmentList: View {
    let attachments: [MessageAttachment]
    let canEditImages: Bool
    let onAddAttachment: (() -> Void)?
    let onClickAttachment: ((Int) -> Void)?
    let onCloseAttachment: (Int) -> Void
    let onClose: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(attachments: [MessageAttachment], canEditImages: Bool = false, onAddAttachment: (() -> Void)? = nil,
                onClickAttachment: ((Int) -> Void)? = nil, onCloseAttachment: @escaping (Int) -> Void = { _ in }, onClose: (() -> Void)? = nil) {
        self.attachments = attachments
        self.canEditImages = canEditImages
        self.onAddAttachment = onAddAttachment
        self.onClickAttachment = onClickAttachment
        self.onCloseAttachment = onCloseAttachment
        self.onClose = onClose
    }

    var allVisual: Bool { attachments.allSatisfy { $0.isImage || $0.isVideo } }

    public var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let onClose, attachments.count > 1 {
                    Color.clear.frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            SwiftUI.Button(action: onClose) {
                                SignalIcon("v3/x/x", size: 20, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.white), mask: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(i18n("icu:close"))
                            .padding(.top, 8)
                            .padding(.trailing, 16)
                        }
                }
                rail
            }
        }
    }

    /// `.module-attachments__rail`: 12px above and before, 12px of trailing padding, 6px below;
    /// at most 142px tall (overflow hidden); white-space nowrap with inline tiles, while generic
    /// tiles are block-level flex boxes and so start new lines.
    var rail: some View {
        let lines = Self.lines(attachments)
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { li in
                // vertical-align: middle (tiles and the placeholder with its 1px margin)
                HStack(alignment: .center, spacing: 0) {
                    ForEach(lines[li], id: \.self) { i in tile(i) }
                    if li == lines.count - 1, allVisual, let onAddAttachment {
                        StagedPlaceholderAttachment(onClick: onAddAttachment)
                    }
                }
            }
        }
        .padding(.trailing, 12)
        return Group {
            if staticRendering {
                content.fixedSize().frame(maxWidth: .infinity, maxHeight: 142, alignment: .topLeading).clipped()
            } else {
                ScrollView(.horizontal) { content }.frame(maxHeight: 142).clipped()
            }
        }
        .padding(.top, 12)
        .padding(.leading, 12)
        .padding(.bottom, 6)
    }

    /// Line boxes of the rail: consecutive visual tiles share a line; each generic tile is a
    /// block of its own.
    static func lines(_ attachments: [MessageAttachment]) -> [[Int]] {
        var out: [[Int]] = [], current: [Int] = []
        for (i, a) in attachments.enumerated() {
            if isVisualTile(a) {
                current.append(i)
            } else {
                if !current.isEmpty { out.append(current); current = [] }
                out.append([i])
            }
        }
        if !current.isEmpty || out.isEmpty { out.append(current) }
        return out
    }

    static func isVisualTile(_ a: MessageAttachment) -> Bool {
        (a.isImage && a.areDimensionsDisplayableForDraft) || a.isVideo || a.pending
    }

    @ViewBuilder func tile(_ i: Int) -> some View {
        let a = attachments[i]
        if Self.isVisualTile(a) {
            let image = ConversationImage(attachment: a, url: a.image ?? (a.isVideo ? a.screenshot : nil), width: 120, height: 120,
                                          corners: .init(topLeft: .tiny, topRight: .tiny, bottomLeft: .tiny, bottomRight: .tiny),
                                          options: { var o = ConversationImage.Options(); o.closeButton = true; o.playIconOverlay = a.isVideo; return o }(),
                                          // AttachmentList passes no theme: the light default blurhash.
                                          blurHashDark: false,
                                          showVisualAttachment: onClickAttachment.map { f in { f(i) } },
                                          onClickClose: { onCloseAttachment(i) })
                .padding(.trailing, 8)       // .module-staged-attachment: margin-inline-end 8px
            if a.isImage && canEditImages {
                EditableTile { image }
            } else {
                image
            }
        } else {
            StagedGenericAttachment(attachment: a) { onCloseAttachment(i) }
                .padding(.trailing, 8)
        }
    }
}

/// `.module-attachments--editable`: the edit icon (36px black-alpha-60 circle, 20px pencil)
/// over the tile on hover.
struct EditableTile<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovered = false
    var body: some View {
        content
            .overlay {
                if hovered {
                    SignalIcon("v3/edit/edit-compact", size: 20, color: AxoColor(LegacyColor.white), mask: true)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AxoColor(LegacyColor.blackAlpha60)))
                        .offset(x: -4)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
    }
}

extension MessageAttachment {
    /// `areDimensionsDisplayable`: missing dimensions count as displayable.
    var areDimensionsDisplayableForDraft: Bool { (height ?? 0) <= 8192 && (width ?? 0) <= 8192 }
}

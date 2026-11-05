// Port of ts/components/stickers/StickerPreviewModal.dom.tsx: the pack preview dialog (cover,
// title, author, count, copy link / remove, the 5-column sticker grid with placeholders for
// stickers not downloaded yet), the error and initial-download states, and the install footer.

import AppKit
import SignalI18n
import SwiftUI

public struct StickerPreviewModal: View {
    let pack: StickerPack?
    let closeStickerPackPreview: () -> Void
    /// `downloadStickerPack(id, key, finalStatus)`.
    let downloadStickerPack: (String, String, StickerPack.Status?) -> Void
    let installStickerPack: (String, String) -> Void
    let uninstallStickerPack: (String, String) -> Void
    let showCopiedLinkToast: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(pack: StickerPack?, closeStickerPackPreview: @escaping () -> Void = {},
                downloadStickerPack: @escaping (String, String, StickerPack.Status?) -> Void = { _, _, _ in },
                installStickerPack: @escaping (String, String) -> Void = { _, _ in },
                uninstallStickerPack: @escaping (String, String) -> Void = { _, _ in }, showCopiedLinkToast: @escaping () -> Void = {}) {
        self.pack = pack
        self.closeStickerPackPreview = closeStickerPackPreview
        self.downloadStickerPack = downloadStickerPack
        self.installStickerPack = installStickerPack
        self.uninstallStickerPack = uninstallStickerPack
        self.showCopiedLinkToast = showCopiedLinkToast
    }

    /// `artAddStickersRoute.toWebUrl`: the pack key is base64 in the store and hex in the link.
    static func link(packId: String, packKey: String) -> String {
        let digits = Array("0123456789abcdef")
        let hex = String((Data(base64Encoded: packKey) ?? Data()).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] })
        return "https://signal.art/addstickers/#pack_id=\(packId)&pack_key=\(hex)"
    }

    func copyLink() {
        guard let pack else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.link(packId: pack.id, packKey: pack.key), forType: .string)
        showCopiedLinkToast()
    }

    func startUninstall() {
        guard let pack, let modals else { return }
        let id = "sticker-preview-uninstall-\(pack.id)"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:stickers--StickerManager--UninstallWarning")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:stickers--StickerManager--Uninstall"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    uninstallStickerPack(pack.id, pack.key)
                }
            }
        }
    }

    func install() {
        guard let pack else { return }
        if pack.status == .ephemeral {
            downloadStickerPack(pack.id, pack.key, .installed)
        } else {
            installStickerPack(pack.id, pack.key)
        }
    }

    /// `isInstallFooterVisible`
    var installFooterVisible: Bool {
        guard let pack else { return false }
        return pack.status != .error && pack.status != .installed
    }

    public var body: some View {
        // The floating header lies over the body, which keeps its full padding.
        AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                if let pack { PackBody(pack: pack, copyLink: copyLink, startUninstall: startUninstall) }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    if installFooterVisible, let pack {
                        AxoDialog.Action(i18n("icu:stickers--StickerPreview--Install"), variant: .strongPrimary, pending: pack.status == .pending,
                                         action: install)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) {
                AxoDialog.Title(i18n("icu:stickers--StickerPreview--Title"))
                AxoDialog.Close(action: closeStickerPackPreview)
            }
        }
        .onAppear {
            // Known packs download on open (`useEffect(…, [])`).
            if let pack, pack.status == .known { downloadStickerPack(pack.id, pack.key, nil) }
        }
    }

    /// `renderBody`
    struct PackBody: View {
        let pack: StickerPack
        let copyLink: () -> Void
        let startUninstall: () -> Void
        @Environment(\.i18n) var i18n

        var body: some View {
            if pack.status == .error {
                CSSText(i18n("icu:stickers--StickerPreview--Error"), type: .bodyMedium, alignment: .center, color: .labelDestructive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if pack.stickerCount == 0 {
                SpinnerV2(variant: .noBackgroundLight, size: 56, strokeWidth: 2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    if let cover = pack.cover {
                        PixelImage(cover, fit: .contain).frame(width: 80, height: 80).padding(.bottom, 16)
                    }
                    title.frame(height: 24).padding(.bottom, 8)
                    VStack(spacing: 0) {
                        CSSText(pack.author, type: .bodyMedium, alignment: .center, color: .labelSecondary).frame(minHeight: 18)
                        CSSText(i18n("icu:stickers--StickerPreview--StickerCount", ["count": .int(pack.stickerCount)]), type: .bodyMedium,
                                alignment: .center, color: .labelSecondary)
                    }
                    .padding(.bottom, 12)
                    AxoStackedButton.Row(spacing: .md) {
                        AxoStackedButton.Root(symbol: "link", label: i18n("icu:stickers--StickerPreview--Link"), onClick: copyLink)
                        if pack.status == .installed {
                            AxoStackedButton.Root(symbol: "minus-circle", label: i18n("icu:stickers--StickerPreview--Remove"), onClick: startUninstall)
                        }
                    }
                    StickerGrid(stickers: pack.stickers, placeholders: max(0, pack.stickerCount - pack.stickers.count))
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity)
            }
        }

        var title: some View {
            HStack(spacing: 0) {
                CSSText(runs: [Emojify.run(pack.title)], style: CSSTextStyle(AxoType.titleMedium), color: .labelPrimary)
                if pack.isBlessed { OfficialChatInlineBadge(size: 18).padding(.leading, 6) }
            }
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// `grid w-max max-w-full grid-cols-5 items-center justify-center gap-2.5`: square cells
    /// of a fifth of the width (at most 72px), stickers `object-contain`, placeholders
    /// `rounded-md bg-primary`.
    struct StickerGrid: View {
        let stickers: [Sticker]
        let placeholders: Int
        @Environment(\.i18n) var i18n

        var body: some View {
            Grid5(gap: 10, maxCell: 72) {
                ForEach(Array(stickers.enumerated()), id: \.offset) { _, sticker in
                    Group {
                        if let image = sticker.image { PixelImage(image, fit: .contain) } else { Color.clear }
                    }
                    .accessibilityLabel(sticker.emoji ?? i18n("icu:stickers--StickerPreview--StickerNoEmojiAriaLabel"))
                }
                ForEach(0..<placeholders, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(AxoColor.fillPrimary)
                }
            }
        }
    }

    /// Chromium paints these `<img>`s (512px stickers in ~62.4px cells) as whole-pixel 62px
    /// squares, left edges rounded up to the device pixel and tops up to the CSS pixel (read
    /// off the captures); the cells are placed the same way.
    struct Grid5: Layout {
        let gap: CGFloat
        let maxCell: CGFloat
        static func ceilHalf(_ v: CGFloat) -> CGFloat { (v * 2 - 0.01).rounded(.up) / 2 }
        func cell(_ width: CGFloat) -> CGFloat { min(maxCell, (width - 4 * gap) / 5) }
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? (5 * maxCell + 4 * gap)
            let side = cell(width)
            let rows = (subviews.count + 4) / 5
            return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * side + CGFloat(rows - 1) * gap)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let side = cell(bounds.width)
            let used = 5 * side + 4 * gap
            let x0 = bounds.minX + (bounds.width - used) / 2
            for (i, view) in subviews.enumerated() {
                let x = x0 + CGFloat(i % 5) * (side + gap), y = bounds.minY + CGFloat(i / 5) * (side + gap)
                let painted = side.rounded(.down)
                view.place(at: CGPoint(x: Self.ceilHalf(x), y: (y - 0.01).rounded(.up)), proposal: ProposedViewSize(width: painted, height: painted))
            }
        }
    }
}

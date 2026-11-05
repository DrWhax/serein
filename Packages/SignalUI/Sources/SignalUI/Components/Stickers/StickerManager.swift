// Ports of ts/components/stickers/StickerManager.dom.tsx and StickerManagerPackRow.dom.tsx
// (stylesheets/components/StickerManager.scss): the sticker panel. "All": the Signal Artist
// Series packs and the packs shared with you (each with install / installed); "My stickers":
// the installed packs (reorderable), or the empty state.
//
// Not ported yet: drag reordering of installed packs (the drag handle).

import SignalI18n
import SwiftUI

/// `StickerPackType` (the parts the manager shows).
public struct StickerPack: Identifiable, Sendable {
    public enum Status: String, Sendable { case known, ephemeral, downloaded, installed, pending, error }
    public var id: String
    public var key: String
    public var title: String
    public var author: String
    public var isBlessed = false
    public var status: Status
    public var cover: RGBAImage?
    public var stickerCount: Int
    public var stickers: [Sticker]
    public init(id: String, key: String = "", title: String, author: String = "", isBlessed: Bool = false, status: Status, cover: RGBAImage? = nil,
                stickerCount: Int = 0, stickers: [Sticker] = []) {
        self.stickerCount = stickerCount
        self.stickers = stickers
        self.id = id
        self.key = key
        self.title = title
        self.author = author
        self.isBlessed = isBlessed
        self.status = status
        self.cover = cover
    }
}

/// `StickerType` (the parts the preview shows): `image` is the decoded sticker, nil while it loads.
public struct Sticker: Sendable {
    public var id: Int
    public var emoji: String?
    public var image: RGBAImage?
    public init(id: Int, emoji: String? = nil, image: RGBAImage? = nil) {
        self.id = id
        self.emoji = emoji
        self.image = image
    }
}

public struct StickerManagerPackRow: View {
    public enum Control: Sendable { case installButton, dragHandle }
    let pack: StickerPack
    let control: Control
    let onClickPreview: (String) -> Void
    let install: (StickerPack) -> Void
    let uninstall: (StickerPack) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(pack: StickerPack, control: Control, onClickPreview: @escaping (String) -> Void = { _ in }, install: @escaping (StickerPack) -> Void = { _ in },
                uninstall: @escaping (StickerPack) -> Void = { _ in }) {
        self.pack = pack
        self.control = control
        self.onClickPreview = onClickPreview
        self.install = install
        self.uninstall = uninstall
    }

    /// Uninstalling a pack that is not blessed asks first (it may not be re-installable).
    func handleUninstall() {
        guard !pack.isBlessed, let modals else { return uninstall(pack) }
        let id = "uninstall-\(pack.id)"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: nil, description: i18n("icu:stickers--StickerManager--UninstallWarning")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                AxoConfirmDialog.Action(i18n("icu:stickers--StickerManager--Uninstall"), variant: .strongDestructive) {
                    modals.dismiss(id: id)
                    uninstall(pack)
                }
            }
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let cover = pack.cover { PixelImage(cover, fit: .contain) } else { Rectangle().fill(AxoColor(LegacyColor.gray05)) }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    CSSText(runs: [Emojify.run(pack.title)], style: CSSTextStyle(AxoType.bodyMedium), wrap: .truncate, color: .labelPrimary)
                    if pack.isBlessed { OfficialChatInlineBadge(size: 13).padding(.leading, 4) }
                }
                .frame(height: 18)
                .padding(.bottom, 2)
                CSSText(pack.author, type: .bodySmall, wrap: .truncate, color: .labelSecondary).frame(height: 16)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch control {
            case .installButton:
                Group {
                    if pack.status == .installed {
                        AxoIconButton.Root(label: i18n("icu:stickers--StickerManager--Installed"), tooltip: false, variant: .strongSecondary, size: .md,
                                           symbol: "check", disabled: true)
                    } else {
                        AxoIconButton.Root(label: i18n("icu:stickers--StickerManager--Install"), variant: .strongSecondary, size: .md, symbol: "plus") {
                            install(pack)
                        }
                    }
                }
                .frame(height: 36)
            case .dragHandle:
                AxoSymbol.Icon("drag-handle", size: 20, label: nil).cssTextColor(.labelSecondary).frame(height: 36)
            }
        }
        .padding(.vertical, 10).padding(.trailing, 10).padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture { onClickPreview(pack.id) }
        .contextMenu {
            if pack.status == .installed {
                Button(i18n("icu:stickers--StickerManagerPackContextMenu--Remove"), action: handleUninstall)
            } else {
                Button(i18n("icu:stickers--StickerManagerPackContextMenu--Add")) { install(pack) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pack.title)
    }
}

public struct StickerManager: View {
    public enum Tab: Sendable { case all, myStickers }
    let tab: Tab
    let blessedPacks: [StickerPack]
    let receivedPacks: [StickerPack]
    let installedPacks: [StickerPack]
    let setTabAll: () -> Void
    let onClickPreview: (String) -> Void
    let install: (StickerPack) -> Void
    let uninstall: (StickerPack) -> Void
    @Environment(\.i18n) var i18n
    /// The panel focuses itself on mount (`focusRef.current.focus()`), showing its ring.
    private var focus = AxoFocusState()

    public init(tab: Tab = .all, blessedPacks: [StickerPack], receivedPacks: [StickerPack], installedPacks: [StickerPack],
                setTabAll: @escaping () -> Void = {}, onClickPreview: @escaping (String) -> Void = { _ in },
                install: @escaping (StickerPack) -> Void = { _ in }, uninstall: @escaping (StickerPack) -> Void = { _ in }) {
        self.tab = tab
        self.blessedPacks = blessedPacks
        self.receivedPacks = receivedPacks
        self.installedPacks = installedPacks
        self.setTabAll = setTabAll
        self.onClickPreview = onClickPreview
        self.install = install
        self.uninstall = uninstall
    }

    func rows(_ packs: [StickerPack], _ control: StickerManagerPackRow.Control) -> some View {
        VStack(spacing: 0) {
            ForEach(packs) { StickerManagerPackRow(pack: $0, control: control, onClickPreview: onClickPreview, install: install, uninstall: uninstall) }
        }
    }

    func heading(_ key: String) -> some View {
        CSSText(i18n(key), style: CSSTextStyle(AxoType.bodyMedium.weight(600)), color: .labelPrimary)
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .all:
                // The heading's top margin and the trailing margins collapse out of the panel.
                heading("icu:stickers--StickerManager--BlessedPacks").padding(.bottom, 4)
                if blessedPacks.isEmpty {
                    CSSText(i18n("icu:stickers--StickerManager--BlessedPacks--Empty"), type: .bodySmall, color: .labelSecondary)
                        .padding(.horizontal, 8)
                } else {
                    rows(blessedPacks, .installButton)
                }
                if !receivedPacks.isEmpty {
                    heading("icu:stickers--StickerManager--ReceivedPacks2").padding(.top, 16).padding(.bottom, 2)
                    CSSText(i18n("icu:stickers--StickerManager--ReceivedPacksDescription"), type: .bodySmall, color: .labelSecondary)
                        .padding(.horizontal, 8).padding(.bottom, 4)
                    rows(receivedPacks, .installButton)
                }
            case .myStickers:
                if installedPacks.isEmpty {
                    VStack(spacing: 0) {
                        CSSText(i18n("icu:stickers--StickerManager--MyStickers--None"), type: .bodyMedium, alignment: .center, color: .labelSecondary)
                            .padding(.bottom, 16)
                        AxoButton.Root(i18n("icu:stickers--StickerManager--AddStickers"), variant: .strongSecondary, size: .md, action: setTabAll)
                    }
                    .frame(maxWidth: 240)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    rows(installedPacks, .dragHandle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(maxWidth: 608)
        .focusable()
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { _, isFocused in if !isFocused { focus.autoFocusConsumed = true } }
        .axoFocusRing(focus.visible(autoFocus: true), in: Rectangle())
        .frame(maxWidth: .infinity)
    }
}

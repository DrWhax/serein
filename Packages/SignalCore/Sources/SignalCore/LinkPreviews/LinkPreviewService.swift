// ts/services/LinkPreview.preload.ts `getPreview`: a preview for a link in the composer —
// sticker pack links (the pack's cover), group invite links (the group's title, size and
// avatar), call links (title only), other https pages (OpenGraph metadata + image).
// Upstream gives up after 60 s; so does this.

import Foundation
import GRDB
import MediaXPCInterface
import SignalText

/// The strings a preview carries (they are sent with the message, in the sender's language).
public struct LinkPreviewStrings: Sendable {
    /// icu:stickers--StickerPackLinkPreviewDescription {author}
    public var stickerPackDescription: @Sendable (String) -> String
    /// icu:GroupV2--join--group-metadata--full {memberCount}
    public var groupDescription: @Sendable (Int) -> String
    /// icu:unknownGroup
    public var unknownGroup: String
    /// icu:calling__call-link-default-title, icu:message--call-link-description
    public var callLinkTitle: String
    public var callLinkDescription: String

    public init(stickerPackDescription: @escaping @Sendable (String) -> String, groupDescription: @escaping @Sendable (Int) -> String,
                unknownGroup: String, callLinkTitle: String, callLinkDescription: String) {
        self.stickerPackDescription = stickerPackDescription
        self.groupDescription = groupDescription
        self.unknownGroup = unknownGroup
        self.callLinkTitle = callLinkTitle
        self.callLinkDescription = callLinkDescription
    }
}

/// `LinkPreviewDraftType`
public struct LinkPreviewDraft: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var description: String?
    public var date: Int64?
    public var image: LinkPreviewImage?
    public var domain: String?
    public var isStickerPack: Bool
    public var isCallLink: Bool

    public init(url: String, title: String?, description: String?, date: Int64?, image: LinkPreviewImage?, isStickerPack: Bool = false,
                isCallLink: Bool = false) {
        self.url = url
        self.title = title
        self.description = description
        self.date = date
        self.image = image
        domain = LinkPreviewRules.domain(url)
        self.isStickerPack = isStickerPack
        self.isCallLink = isCallLink
    }
}

public struct LinkPreviewService: Sendable {
    public static let timeout: Duration = .seconds(60)
    let transport: any LinkPreviewTransport
    let media: any MediaProcessing
    let stickers: StickerService?
    let groups: GroupsService?
    let strings: LinkPreviewStrings

    public init(transport: any LinkPreviewTransport, media: any MediaProcessing, stickers: StickerService?, groups: GroupsService?,
                strings: LinkPreviewStrings) {
        self.transport = transport
        self.media = media
        self.stickers = stickers
        self.groups = groups
        self.strings = strings
    }

    /// The "Generate link previews" setting (`getLinkPreviewSetting`).
    public static func isEnabled(_ db: Database) throws -> Bool { try Items.get(db, "linkPreviews", as: Bool.self) ?? false }

    /// `getPreview`, bounded by `timeout`.
    public func preview(for url: String) async -> LinkPreviewDraft? {
        await withTaskGroup(of: LinkPreviewDraft?.self) { group in
            group.addTask { await self.fetchPreview(url) }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func fetchPreview(_ url: String) async -> LinkPreviewDraft? {
        if let pack = LinkPreviewRules.stickerPack(url) { return await stickerPackPreview(url, pack) }
        if LinkPreviewRules.groupInviteFragment(url) != nil { return await groupPreview(url) }
        if LinkPreviewRules.isCallLink(url) {
            // Call link state comes with calling (Phase 6); the default title until then.
            return LinkPreviewDraft(url: url, title: strings.callLinkTitle, description: strings.callLinkDescription, date: nil, image: nil, isCallLink: true)
        }
        guard LinkPreviewRules.shouldPreviewHref(url), let meta = await LinkPreviewFetch.metadata(transport, media: media, href: url) else { return nil }
        var image = meta.image
        if image == nil, let href = meta.imageHref, LinkPreviewRules.shouldPreviewHref(href) {
            image = await LinkPreviewFetch.image(transport, media: media, href: href)
        }
        guard !Task.isCancelled else { return nil }
        return LinkPreviewDraft(url: url, title: meta.title, description: meta.description, date: meta.date, image: image)
    }

    /// `getStickerPackPreview`
    func stickerPackPreview(_ url: String, _ pack: (packId: String, packKey: String)) async -> LinkPreviewDraft? {
        guard let stickers, let key = Data(hex: pack.packKey),
              let p = try? await stickers.preview(packId: pack.packId, packKey: key.base64EncodedString()) else { return nil }
        let contentType = Stickers.sniffContentType(p.cover) ?? "image/webp"
        return LinkPreviewDraft(url: url, title: p.title, description: strings.stickerPackDescription(p.author), date: nil,
                                image: LinkPreviewImage(data: p.cover, contentType: contentType), isStickerPack: true)
    }

    /// `getGroupPreview`
    func groupPreview(_ url: String) async -> LinkPreviewDraft? {
        guard let groups, let link = try? GroupLink(url: url), let info = try? await groups.preJoinInfo(link) else { return nil }
        var image: LinkPreviewImage? = nil
        if let avatarKey = info.avatarKey, let keys = try? GroupKeys(masterKey: link.masterKey),
           let blob = try? await groups.api.avatar(avatarKey), let data = try? GroupsService.decryptAvatar(blob, keys: keys) {
            image = LinkPreviewImage(data: data, contentType: "image/jpeg")
        }
        let title = info.title.flatMap { $0.isEmpty ? nil : $0 } ?? strings.unknownGroup
        return LinkPreviewDraft(url: url, title: title, description: strings.groupDescription(info.memberCount), date: nil, image: image)
    }
}

// The composer's link preview (ts/services/LinkPreview.preload.ts `maybeGrabLinkPreview`,
// `addLinkPreview`, `getLinkPreviewsForSend`): the first previewable link in the draft is
// fetched 200 ms after typing stops, directly from the site as upstream Desktop does (Signal's
// content proxy refuses most sites). The page is parsed by
// SignalLinkPreviewParser.xpc (its own tight Seatbelt sandbox); the image is sized by, and
// decoded for display by, SignalMediaDecoder.xpc (our Swift decoders). Closing a preview, or a
// failed fetch, leaves that link out until the next send.

import Foundation
import MediaXPCInterface
import SignalCore
import SignalText
import SignalUI

/// The composer's preview: loading (no draft yet) or fetched.
struct ComposerLinkPreview {
    var url: String
    var draft: LinkPreviewDraft?
    /// The draft's image, decoded by the media service.
    var image: RGBAImage?
}

@MainActor extension SignalSession {
    /// The preview's image at most this big (the 72 pt thumbnail at 2×).
    static let linkPreviewImageMaxDimension = 144

    /// `maybeGrabLinkPreview`, debounced (200 ms after the last change).
    func maybeGrabLinkPreview() {
        linkPreviewDebounce?.cancel()
        if draft.isEmpty { return removeLinkPreview() }
        linkPreviewDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.grabLinkPreview()
        }
    }

    private func grabLinkPreview() {
        // Previews are off, or the message has attachments or is an edit: none.
        guard !draft.isEmpty, staged.isEmpty, editingMessageId == nil else { return removeLinkPreview() }
        let all = LinkPreviewRules.findLinks(draft)
        guard accountSettings.linkPreviews else {
            if !all.isEmpty { Self.trace("link preview: off (Settings → Chats → Generate link previews)") }
            return removeLinkPreview()
        }
        if let current = linkPreview?.url, all.contains(current) { return }
        guard let link = all.first(where: { LinkPreviewRules.shouldPreviewHref($0) && !linkPreviewExcluded.contains($0) }) else {
            if !all.isEmpty { Self.trace("link preview: \(all.count) links, none previewable") }
            return removeLinkPreview()
        }
        Self.trace("link preview: fetching \(LinkPreviewRules.domain(link) ?? "?")")
        removeLinkPreview()
        linkPreview = ComposerLinkPreview(url: link)
        linkPreviewTask = Task { [weak self] in await self?.fetchLinkPreview(link) }
    }

    /// `addLinkPreview`: the fetch (bounded by LinkPreviewService.timeout), then its image.
    private func fetchLinkPreview(_ url: String) async {
        let loaded = await loadLinkPreview(url, maxDimension: Self.linkPreviewImageMaxDimension)
        guard !Task.isCancelled, linkPreview?.url == url else { return }
        guard let loaded else {
            linkPreviewExcluded.insert(url)
            return removeLinkPreview()
        }
        linkPreview = loaded
    }

    /// A link's preview and its image decoded for display; nil without a title or an image.
    private func loadLinkPreview(_ url: String, maxDimension: Int) async -> ComposerLinkPreview? {
        guard let service = linkPreviewService() else {
            Self.trace("link preview: no service (session \(signalSession != nil), strings \(linkPreviewStrings != nil))")
            return nil
        }
        let result = await service.preview(for: url)
        Self.trace("link preview: \(result == nil ? "no result" : "title \(result?.title?.isEmpty == false), image \(result?.image?.data.count ?? 0) bytes")")
        // A preview needs a title or an image.
        guard let result, result.title?.isEmpty == false || result.image != nil else { return nil }
        var image: RGBAImage?
        if let data = result.image?.data, let shown = try? await media.displayImage(data, maxDimension: maxDimension) {
            image = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
        } else if result.image != nil {
            Self.trace("link preview: image not decodable")
        }
        return ComposerLinkPreview(url: url, draft: result, image: image)
    }

    // MARK: the text story creator's (LinkPreviewSourceType.StoryCreator, mode 'story')

    /// `debouncedMaybeGrabLinkPreview` for a story: with previews off, the link alone
    /// (`disableFetch`); a failed fetch leaves it out.
    func grabStoryLinkPreview(_ text: String) {
        storyLinkPreviewDebounce?.cancel()
        storyLinkPreviewDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.findStoryLinkPreview(text)
        }
    }

    private func findStoryLinkPreview(_ text: String) {
        guard !text.isEmpty else { return removeStoryLinkPreview() }
        let all = LinkPreviewRules.findLinks(text)
        if let current = storyLinkPreview?.url, all.contains(current) { return }
        guard let link = all.first(where: { LinkPreviewRules.shouldPreviewHref($0) && !storyLinkPreviewExcluded.contains($0) }) else {
            return removeStoryLinkPreview()
        }
        removeStoryLinkPreview()
        guard accountSettings.linkPreviews else {
            storyLinkPreview = ComposerLinkPreview(url: link, draft: LinkPreviewDraft(url: link, title: nil, description: nil, date: nil, image: nil))
            return
        }
        storyLinkPreview = ComposerLinkPreview(url: link)
        storyLinkPreviewTask = Task { [weak self] in
            let loaded = await self?.loadLinkPreview(link, maxDimension: Self.storyLinkPreviewImageMaxDimension)
            guard !Task.isCancelled, let self, self.storyLinkPreview?.url == link else { return }
            guard let loaded else {
                self.storyLinkPreviewExcluded.insert(link)
                return self.removeStoryLinkPreview()
            }
            self.storyLinkPreview = loaded
        }
    }

    /// The story card's image at most this big (its full-width card at 2×).
    static let storyLinkPreviewImageMaxDimension = 720

    func removeStoryLinkPreview() {
        storyLinkPreviewDebounce?.cancel()
        storyLinkPreviewTask?.cancel()
        storyLinkPreviewTask = nil
        if storyLinkPreview != nil { storyLinkPreview = nil }
    }

    /// A new story, or one sent: nothing left out any more.
    func resetStoryLinkPreview() {
        storyLinkPreviewExcluded = []
        removeStoryLinkPreview()
    }

    /// The creator's `linkPreview` (none while loading).
    var storyCreatorLinkPreview: StoryCreatorLinkPreview? {
        guard let p = storyLinkPreview, let d = p.draft else { return nil }
        return StoryCreatorLinkPreview(url: d.url, title: d.title, description: d.description, image: p.image,
                                       imageSize: p.image.map { CGSize(width: $0.width, height: $0.height) }, domain: LinkPreviewRules.domain(d.url))
    }

    /// The story's preview as sent: the fetched one for its link (with date and image), else
    /// the card's own fields.
    func storyLinkPreviewForSend(_ p: StoryLinkPreviewData) -> (preview: SignalCore.StoryLinkPreview, image: OutgoingAttachment?) {
        guard let d = storyLinkPreview?.draft, d.url == p.url else {
            return (SignalCore.StoryLinkPreview(url: p.url, title: p.title, description: p.description), nil)
        }
        return (SignalCore.StoryLinkPreview(url: d.url, title: d.title, description: d.description, date: d.date),
                d.image.map { OutgoingAttachment(data: $0.data, contentType: $0.contentType) })
    }

    private func linkPreviewService() -> LinkPreviewService? {
        guard let session = signalSession, let strings = linkPreviewStrings else { return nil }
        var service = LinkPreviewService(fetcher: linkPreviewFetcher, media: media,
                                         stickers: session.stickers, groups: session.groups, strings: strings)
        service.log = { Self.trace("link preview: \($0)") }
        return service
    }

    /// `onCloseLinkPreview`
    func closeLinkPreview() {
        if let url = linkPreview?.url { linkPreviewExcluded.insert(url) }
        removeLinkPreview()
    }

    func removeLinkPreview() {
        linkPreviewDebounce?.cancel()
        linkPreviewTask?.cancel()
        linkPreviewTask = nil
        if linkPreview != nil { linkPreview = nil }
    }

    /// `resetLinkPreview`: after a send, or on leaving the chat.
    func resetLinkPreview() {
        linkPreviewExcluded = []
        removeLinkPreview()
    }

    /// `getLinkPreviewsForSend`: the fetched preview, if its link is still in the message.
    func linkPreviewForSend(_ body: String) -> LinkPreviewDraft? {
        guard accountSettings.linkPreviews, let p = linkPreview?.draft, LinkPreviewRules.findLinks(body).contains(p.url) else { return nil }
        return p
    }

    /// The composer's StagedLinkPreview: the link alone while loading.
    var composerLinkPreview: LinkPreview? {
        guard let p = linkPreview else { return nil }
        guard let d = p.draft else { return LinkPreview(url: p.url) }
        var image: SignalUI.MessageAttachment?
        if let i = d.image {
            var a = SignalUI.MessageAttachment(contentType: i.contentType, fileName: nil, size: i.data.count, width: p.image?.width, height: p.image?.height)
            a.image = p.image
            a.isDownloaded = true
            image = p.image == nil ? nil : a
        }
        var out = LinkPreview(url: d.url, domain: d.domain, title: d.title, description: d.description, date: d.date.map(Double.init), image: image)
        out.isStickerPack = d.isStickerPack
        out.isCallLink = d.isCallLink
        return out
    }
}

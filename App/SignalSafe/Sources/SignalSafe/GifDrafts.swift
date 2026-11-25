// A GIF picked in the Fun picker (CompositionArea's handleFunPickerSelectGif and
// SmartDraftGifMessageSendModal): with attachments staged, first "replace them?"; then the GIF,
// downloaded and playing, with the composer's text to edit before Send; sending it clears the
// composer's text, as the message carries it.

import Foundation
import SignalCore
import SignalUI

/// `DraftGifMessageSendModal`'s state.
struct DraftGif {
    let conversationId: String
    let gif: FunGifItem
    var text: String
    var state: FunLoadingState = .loading
    var data: Data?
    var player: VideoPlaybackEngine?
}

extension SignalSession {
    /// `handleFunPickerSelectGif`
    func selectGif(_ gif: FunGifItem) {
        if !staged.isEmpty {
            confirmGifSelection = gif
        } else {
            openDraftGif(gif)
        }
    }

    /// `handleConfirmGifSelection`: the staged attachments go, the GIF's dialog opens.
    func replaceAttachmentsWithGif() {
        guard let gif = confirmGifSelection else { return }
        confirmGifSelection = nil
        clearStaged()
        openDraftGif(gif)
    }

    func openDraftGif(_ gif: FunGifItem) {
        guard let c = selectedConversation else { return }
        closeDraftGif()
        draftGif = DraftGif(conversationId: c.id, gif: gif, text: draft)
        guard let giphy else {
            draftGif?.state = .loadFailed
            return
        }
        let media = media
        draftGifTask = Task { [weak self] in
            do {
                let data = try await giphy.file(gif.attachmentMedia.url)
                guard !Task.isCancelled else { return }
                let opened = try await media.openVideo(data)
                let engine = VideoPlaybackEngine()
                engine.isLooping = true
                await engine.load(XPCVideoSource(media: media, session: opened.session), duration: opened.info.duration, rotation: opened.info.rotation)
                guard !Task.isCancelled, self?.draftGif?.gif.id == gif.id else { return await engine.unload() }
                self?.draftGif?.data = data
                self?.draftGif?.player = engine
                self?.draftGif?.state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                Self.trace("gif download failed: \(error)")
                self?.draftGif?.state = .loadFailed
            }
        }
    }

    func closeDraftGif() {
        draftGifTask?.cancel()
        draftGifTask = nil
        if let player = draftGif?.player { Task { await player.unload() } }
        draftGif = nil
    }

    /// handleSubmit: the GIF with the dialog's text (`sendMultiMediaMessage`), once the safety
    /// numbers are settled; it joins the recent GIFs.
    func sendDraftGif() {
        guard let d = draftGif, d.state == .loaded, let data = d.data, let session = signalSession, let c = conversation(d.conversationId) else { return }
        let body = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        closeDraftGif()
        addRecentGif(d.gif)
        if selectedConversationId == d.conversationId { draft = "" }
        let attachments = [OutgoingAttachment(data: data, contentType: "video/mp4", flags: 8)]
        afterIdentityReview(conversationId: c.id, send: { Task {
            do {
                if c.kind == .group, let key = c.masterKey {
                    _ = try await session.messenger.sendGroupMessage(body, attachments: attachments, masterKey: key)
                } else if let to = c.serviceId {
                    _ = try await session.messenger.sendMessage(body, attachments: attachments, to: to)
                }
            } catch {
                Self.trace("gif send failed: \(error)")
            }
        } })
    }
}

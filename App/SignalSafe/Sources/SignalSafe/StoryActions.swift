// What the Stories tab does with a story beyond viewing it (upstream's stories duck and
// StoryViewer / MyStories / StoriesSettingsModal callbacks): save, forward, delete for
// everyone, retry, hide a sender's stories, the viewers and replies of a story, and the story
// settings (lists, group stories, view receipts, turning stories off).

import AppKit
import Foundation
import SignalCore
import SignalUI

extension SignalSession {
    /// `saveAttachment` for a media story (MyStories download, StoryDetailsModal).
    func saveStory(_ id: String) {
        guard let item = stories.first(where: { $0.id == id }), let media = item.media else { return }
        guard media.isDownloaded else {
            toast = .attachmentDownloadStillInProgress(count: 1)
            return
        }
        let name = Self.suggestedFilename(media, sentAt: item.sentAt, index: 1)
        if Self.isFileDangerous(name) {
            toast = .dangerousFileType
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url, let store = signalSession?.attachmentStore else { return }
        do {
            try store.export(media, to: url)
            toast = .fileSaved(fullPath: url.path, countOfFiles: 1)
        } catch {
            Self.trace("story save failed: \(error)")
            toast = .error
        }
    }

    func deleteStoryForEveryone(_ id: String) {
        run("delete story") { try await $0.messenger.deleteStoryForEveryone(storyId: id) }
    }

    func retryStory(_ id: String) {
        run("retry story") { try await $0.messenger.retryStory(storyId: id) }
    }

    /// `toggleHideStories` for the sender's (or group's) conversation.
    func toggleHideStories(_ conversationId: String) {
        let hidden = stories.first { ($0.groupConversationId ?? $0.conversationId) == conversationId }?.isHidden ?? false
        run("hide stories") { try await $0.messenger.setHideStories(conversationId, !hidden) }
    }

    /// Forwarding a story (MyStories "Forward"): its media, or a text story's text, to chats.
    func doForwardStory(_ id: String, to conversationIds: [String], body edited: String?) {
        guard let session = signalSession, let item = stories.first(where: { $0.id == id }) else { return }
        let targets = conversationIds.compactMap { id in conversation(id) ?? composable.first { $0.id == id } }
        let store = session.attachmentStore
        let text = edited ?? item.text?.text ?? ""
        Task {
            var attachments: [OutgoingAttachment] = []
            if let media = item.media, let data = (try? store.plaintext(of: media)) ?? nil {
                attachments.append(OutgoingAttachment(data: data, contentType: media.contentType, fileName: media.fileName, flags: media.flags))
            }
            guard !text.isEmpty || !attachments.isEmpty else { return }
            for t in targets {
                do {
                    if t.kind == .group, let key = t.masterKey {
                        _ = try await session.messenger.sendGroupMessage(text, attachments: attachments, masterKey: key)
                    } else if let to = t.serviceId {
                        _ = try await session.messenger.sendMessage(text, attachments: attachments, to: to)
                    }
                } catch {
                    Self.trace("story forward failed: \(error)")
                }
            }
        }
    }

    // MARK: viewers and replies

    func storyRecipients(_ id: String) async -> [StoryRecipientState] {
        (try? await clientDatabase?.storyRecipients(storyId: id)) ?? []
    }

    func storyReplies(_ id: String) async -> [StoryReplyItem] {
        guard let me = ourAci else { return [] }
        return (try? await clientDatabase?.storyReplies(storyId: id, ourAci: me)) ?? []
    }

    // MARK: settings

    func setStoryViewReceipts(_ on: Bool) {
        run("story view receipts") { try await $0.messenger.setStorySettings(viewReceipts: on) }
    }

    func setStoriesDisabled(_ off: Bool) {
        run("stories disabled") { try await $0.messenger.setStorySettings(storiesDisabled: off) }
    }

    func createStoryList(name: String, members: [String]) {
        run("create story list") { _ = try await $0.messenger.createStoryList(name: name, members: members) }
    }

    func updateStoryList(_ id: String, allowsReplies: Bool? = nil, isBlockList: Bool? = nil, members: [String]? = nil) {
        run("update story list") { try await $0.messenger.updateStoryList(id, allowsReplies: allowsReplies, isBlockList: isBlockList, members: members) }
    }

    func deleteStoryList(_ id: String) {
        run("delete story list") { try await $0.messenger.deleteStoryList(id) }
    }

    func setGroupStorySendMode(_ conversationIds: [String], always: Bool) {
        run("group story send mode") { s in
            for id in conversationIds { try await s.messenger.setGroupStorySendMode(id, always: always) }
        }
    }
}

// More of a chat's settings and group management: custom mute and disappearing-message
// durations, adding members, editing the group (name, description, avatar), chat colours
// (presets and custom colours), forwarding messages, and the banned members.

import AppKit
import Foundation
import SignalCore
import SignalUI
import SwiftUI

/// The custom-colour editor: a new colour, or one being edited (or duplicated).
struct CustomColorEditing {
    var editing: SignalCore.CustomChatColor?
    var duplicate = false
}

@MainActor extension SignalSession {
    // MARK: custom durations

    /// `setMuteExpiration` with an end time (MuteUntilDialog).
    func mute(_ conversationId: String, until date: Date) {
        let until = Int64(date.timeIntervalSince1970 * 1000)
        guard let session = signalSession else { return }
        Task { try? await session.messenger.setMuted(conversationId, until: until) }
    }

    // MARK: members

    /// Contacts that can be added (1:1 chats with a service id, not us).
    func addMemberCandidates() async -> [ConversationSummary] {
        guard let db = clientDatabase else { return [] }
        let me = ourAci
        return ((try? await db.pool.read { try ConversationQueries.composable($0) }) ?? []).filter { $0.kind == .private && $0.serviceId != nil && $0.serviceId != me }
    }

    /// `addMembersToGroup`: the chosen contacts' conversation ids.
    func addMembers(conversationIds: [String], candidates: [ConversationSummary]) {
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let acis = conversationIds.compactMap { byId[$0]?.serviceId }
        guard let keys = details?.masterKey.flatMap({ try? GroupKeys(masterKey: $0) }), let session = signalSession, !acis.isEmpty else { return }
        addMembersState = .active
        Task {
            do {
                try await session.groups.addMembers(keys, acis)
                addMembersState = .inactive
                isAddingMembers = false
            } catch {
                Self.trace("add members failed: \(error)")
                addMembersState = .inactiveWithError
            }
        }
    }

    func unban(_ serviceId: String) {
        guard let keys = details?.masterKey.flatMap({ try? GroupKeys(masterKey: $0) }), let session = signalSession else { return }
        Task {
            do { try await session.groups.unban(keys, serviceId) } catch { Self.trace("unban failed: \(error)") }
        }
    }

    // MARK: editing the group

    /// The edit dialog's photo: its bytes kept for upload, its pixels from the media service.
    func loadGroupPhoto(_ url: URL) async -> RGBAImage? {
        guard let data = try? Data(contentsOf: url), data.count <= 20 << 20,
              let shown = try? await media.displayImage(data, maxDimension: 512) else { return nil }
        let type = url.pathExtension.lowercased()
        pendingGroupPhoto = (data, ["png": "image/png", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"][type] ?? "image/jpeg")
        return RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
    }

    /// `updateGroupAttributes`: title, description and avatar (each only if changed).
    func updateGroup(_ r: EditConversationAttributesModal.Request) {
        guard let keys = details?.masterKey.flatMap({ try? GroupKeys(masterKey: $0) }), let session = signalSession else { return }
        editGroupState = .active
        let photo = pendingGroupPhoto
        let media = media
        // A preset avatar (colour, icon, text) is drawn here; a photo is re-encoded (and its
        // metadata dropped) by the media service.
        var rendered: Data?
        if case .some(.some(let a)) = r.avatar, a.image == nil || photo == nil { rendered = Self.renderAvatar(a) }
        Task {
            do {
                if let title = r.title { try await session.groups.setTitle(keys, title) }
                if let description = r.description { try await session.groups.setDescription(keys, description) }
                switch r.avatar {
                case .none: break
                case .some(.none): try await session.groups.setAvatar(keys, nil)
                case .some(.some):
                    if let rendered {
                        try await session.groups.setAvatar(keys, rendered)
                    } else if let photo {
                        let scaled = try await media.scaleForSending(photo.data, contentType: photo.contentType, level: .one)
                        try await session.groups.setAvatar(keys, scaled.data)
                    }
                }
                pendingGroupPhoto = nil
                editGroupState = .inactive
                isEditingGroup = false
            } catch {
                Self.trace("update group failed: \(error)")
                editGroupState = .inactiveWithError
            }
        }
    }

    /// A preset avatar as a 512px PNG (our own drawing: no untrusted decoding involved).
    static func renderAvatar(_ a: AvatarData) -> Data? {
        let renderer = ImageRenderer(content: AvatarDataImage(data: a, size: 512))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    // MARK: chat colours

    func observeChatColors() {
        guard chatColorsTask == nil, let db = clientDatabase else { return }
        chatColorsTask = Task { [weak self] in
            do {
                for try await s in db.chatColorsUpdates() { self?.chatColors = s }
            } catch {}
        }
    }

    func observeConversationColor() {
        conversationColorTask?.cancel()
        conversationColor = nil
        guard let id = selectedConversationId, let db = clientDatabase else { return }
        observeChatColors()
        conversationColorTask = Task { [weak self] in
            do {
                for try await c in db.conversationColorUpdates(conversationId: id) { self?.conversationColor = c }
            } catch {}
        }
    }

    /// The bubble colour SignalUI draws for a stored colour.
    func bubbleColor(_ c: ChatBubbleColor?) -> BubbleColor {
        let chosen: ChatBubbleColor? = c ?? chatColors.defaultColor
        switch chosen {
        case .preset(let name)?: return .preset(name)
        case .custom(let id)?:
            guard let custom = chatColors.customColors.first(where: { $0.id == id }) else { return .default }
            return Self.bubble(custom)
        case nil: return .default
        }
    }

    static func rgba(_ argb: UInt32) -> RGBA {
        RGBA(Double((argb >> 16) & 0xFF) / 255, Double((argb >> 8) & 0xFF) / 255, Double(argb & 0xFF) / 255, 1)
    }

    static func argb(_ c: RGBA) -> UInt32 {
        func b(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return 0xFF00_0000 | b(c.r) << 16 | b(c.g) << 8 | b(c.b)
    }

    static func bubble(_ c: SignalCore.CustomChatColor) -> BubbleColor {
        if let g = c.gradient { return SignalUI.CustomChatColor.gradient(angle: Double(g.angle), start: rgba(g.start), end: rgba(g.end)) }
        return .solid(rgba(c.solid ?? 0xFF2C_6BED))
    }

    /// The open chat's own colour (nil: back to the default).
    func setConversationColor(_ c: ChatBubbleColor?) {
        guard let id = selectedConversationId, let db = clientDatabase else { return }
        Task { try? await db.pool.write { try ChatColors.setConversationColor($0, conversationId: id, c) } }
    }

    /// CustomColorEditorDialog's result: a new colour (selected for this chat), or the edited one.
    func saveCustomColor(_ color: BubbleColor, editing: CustomColorEditing) {
        guard let db = clientDatabase, let id = selectedConversationId else { return }
        var solid: UInt32?
        var gradient: (start: UInt32, end: UInt32, angle: Int)?
        switch color {
        case .solid(let c): solid = Self.argb(c)
        case .gradient(let g): gradient = (Self.argb(g.start), Self.argb(g.end), Int((270 - g.deg).rounded()) % 360)
        case .preset: return
        }
        customColorEditor = nil
        let (s, g) = (solid, gradient)
        Task {
            try? await db.pool.write { db in
                if let existing = editing.editing, !editing.duplicate {
                    try ChatColors.updateCustomColor(db, SignalCore.CustomChatColor(id: existing.id, solid: s, gradient: g))
                } else {
                    let new = try ChatColors.addCustomColor(db, solid: s, gradient: g)
                    try ChatColors.setConversationColor(db, conversationId: id, .custom(new))
                }
            }
        }
    }

    func removeCustomColor(_ id: Int64) {
        guard let db = clientDatabase else { return }
        Task { try? await db.pool.write { try ChatColors.removeCustomColor($0, id: id) } }
    }

    /// "Reset all chat colors": every chat back to the default.
    func resetAllChatColors() {
        guard let db = clientDatabase else { return }
        Task { try? await db.pool.write { try $0.execute(sql: "UPDATE conversations SET bubbleColorPreset = NULL, customChatColorId = NULL") } }
    }

    // MARK: forwarding

    /// `toggleForwardMessagesModal`
    func forward(_ messageIds: [String]) {
        selectedMessageIds = nil
        forwardMessageIds = messageIds
    }

    /// `doForwardMessages`: each message (its text, as edited, and its attachments, or its
    /// sticker) to each chosen chat.
    func doForward(to conversationIds: [String], drafts: [MessageForwardDraft]) {
        guard let session = signalSession, let ids = forwardMessageIds else { return }
        forwardMessageIds = nil
        let sources = ids.compactMap { id in messages.first { $0.id == id } }
        let targets = conversationIds.compactMap { id in conversation(id) ?? composable.first { $0.id == id } }
        let store = session.attachmentStore
        Task {
            for (i, m) in sources.enumerated() {
                let body = i < drafts.count ? drafts[i].messageBody : m.body
                var attachments: [OutgoingAttachment] = []
                for a in m.attachments.map(\.attachment) {
                    guard let data = (try? store.plaintext(of: a)) ?? nil else { continue }
                    attachments.append(OutgoingAttachment(data: data, contentType: a.contentType, fileName: a.fileName, caption: a.caption, flags: a.flags))
                }
                for t in targets {
                    do {
                        if let sticker = m.sticker {
                            if t.kind == .group, let key = t.masterKey {
                                _ = try await session.messenger.sendSticker(packId: sticker.packId, stickerId: sticker.stickerId, masterKey: key)
                            } else if let to = t.serviceId {
                                _ = try await session.messenger.sendSticker(packId: sticker.packId, stickerId: sticker.stickerId, to: to)
                            }
                        } else if t.kind == .group, let key = t.masterKey {
                            _ = try await session.messenger.sendGroupMessage(body, attachments: attachments, masterKey: key)
                        } else if let to = t.serviceId {
                            _ = try await session.messenger.sendMessage(body, attachments: attachments, to: to)
                        }
                    } catch {
                        Self.trace("forward failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: notification profiles

    func setNotificationProfileOverride(_ id: String, enabled: Bool, endsAt: Date?) {
        guard let session = signalSession else { return }
        let end = endsAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        Task {
            do { try await session.messenger.setNotificationProfileOverride(profileId: id, enabled: enabled, endsAt: end) } catch { Self.trace("profile override failed: \(error)") }
        }
    }
}

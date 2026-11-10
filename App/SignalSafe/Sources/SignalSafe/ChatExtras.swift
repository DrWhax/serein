// More of a chat's settings and group management: custom mute and disappearing-message
// durations, adding members, editing the group (name, description, avatar), chat colours
// (presets and custom colours), forwarding messages, and the banned members.

import AppKit
import CodecCore
import EncodePNG
import Foundation
import MediaXPCInterface
import SignalCore
import SignalUI
import SwiftUI

/// The custom-colour editor: a new colour, or one being edited (or duplicated).
struct CustomColorEditing {
    var editing: SignalCore.CustomChatColor?
    var duplicate = false
    /// Opened from Settings → Appearance → Chat color: a new colour becomes the default for
    /// all chats instead of the open chat's.
    var forDefault = false
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
        guard let (photo, image) = await Self.loadPhoto(url, media: media) else { return nil }
        pendingGroupPhoto = photo
        return image
    }

    /// A picked photo file: its bytes and type, and its pixels decoded by the media service.
    static func loadPhoto(_ url: URL, media: MediaXPCClient) async -> ((data: Data, contentType: String), RGBAImage)? {
        guard let data = try? Data(contentsOf: url), data.count <= 20 << 20,
              let shown = try? await media.displayImage(data, maxDimension: 512) else { return nil }
        let type = url.pathExtension.lowercased()
        let contentType = ["png": "image/png", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"][type] ?? "image/jpeg"
        return ((data, contentType), RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2))
    }

    /// The new group's photo (AvatarEditor in the compose flow).
    func loadNewGroupPhoto(_ url: URL) async -> RGBAImage? {
        guard let (photo, image) = await Self.loadPhoto(url, media: media) else { return nil }
        newGroupPhoto = photo
        return image
    }

    /// An avatar's bytes for upload: a photo re-encoded (metadata dropped) by the media service,
    /// a preset drawn here and encoded by our PNG encoder.
    func avatarBytes(_ a: AvatarData, photo: (data: Data, contentType: String)?) async throws -> Data? {
        if a.image != nil, let photo {
            return try await media.scaleForSending(photo.data, contentType: photo.contentType, level: .one).data
        }
        return Self.renderAvatar(a)
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

    /// A preset avatar as a 512px PNG (our own drawing, encoded by our PNG encoder).
    static func renderAvatar(_ a: AvatarData) -> Data? {
        let renderer = ImageRenderer(content: AvatarDataImage(data: a, size: 512))
        renderer.scale = 1
        guard let cg = renderer.cgImage, let pixels = rgba(cg) else { return nil }
        return Data(PNGEncoder.encode(pixels))
    }

    /// A preset avatar's preview pixels (the compose flow's AvatarPreview).
    static func renderAvatarImage(_ a: AvatarData) -> RGBAImage? {
        let renderer = ImageRenderer(content: AvatarDataImage(data: a, size: 96))
        renderer.scale = 2
        guard let cg = renderer.cgImage, let pixels = rgba(cg) else { return nil }
        return RGBAImage(width: pixels.width, height: pixels.height, pixels: Data(pixels.rgba), scale: 2)
    }

    /// The image's pixels as straight-alpha RGBA8, read from its data provider: 8-bit, 4-byte
    /// pixels in any channel order (RGBA, ARGB, either byte order), premultiplied or not, or nil.
    static func rgba(_ image: CGImage) -> PixelBuffer? {
        let (w, h) = (image.width, image.height)
        guard w > 0, h > 0, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let data = image.dataProvider?.data as Data? else { return nil }
        let bytes = [UInt8](data), stride = image.bytesPerRow
        guard stride >= w * 4, bytes.count >= stride * (h - 1) + w * 4 else { return nil }
        let info = image.bitmapInfo
        guard let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) else { return nil }
        let little = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue
        let alphaFirst: Bool
        let hasAlpha: Bool
        switch alpha {
        case .premultipliedLast, .last: (alphaFirst, hasAlpha) = (false, true)
        case .noneSkipLast: (alphaFirst, hasAlpha) = (false, false)
        case .premultipliedFirst, .first: (alphaFirst, hasAlpha) = (true, true)
        case .noneSkipFirst: (alphaFirst, hasAlpha) = (true, false)
        default: return nil
        }
        let premultiplied = alpha == .premultipliedLast || alpha == .premultipliedFirst
        // Byte offsets of R, G, B, A within a pixel.
        var order = alphaFirst ? [1, 2, 3, 0] : [0, 1, 2, 3]
        if little { order = order.map { 3 - $0 } }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * stride + x * 4, o = (y * w + x) * 4
                let a = hasAlpha ? Int(bytes[i + order[3]]) : 255
                for c in 0..<3 {
                    let v = Int(bytes[i + order[c]])
                    // Un-premultiply (rounded).
                    out[o + c] = !premultiplied || a == 255 ? UInt8(v) : a == 0 ? 0 : UInt8(min(255, (v * 255 + a / 2) / a))
                }
                out[o + 3] = UInt8(a)
            }
        }
        return PixelBuffer(width: w, height: h, rgba: out)
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
        let conversationId = editing.forDefault ? nil : selectedConversationId
        guard let db = clientDatabase, editing.forDefault || conversationId != nil else { return }
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
                    // `addCustomColor`: selected for the chat, or as the default.
                    let new = try ChatColors.addCustomColor(db, solid: s, gradient: g)
                    if let conversationId {
                        try ChatColors.setConversationColor(db, conversationId: conversationId, .custom(new))
                    } else {
                        try ChatColors.setDefaultColor(db, .custom(new))
                    }
                }
            }
        }
    }

    /// `setGlobalDefaultBubbleColor` (nil: `resetDefaultChatColor`).
    func setDefaultChatColor(_ c: ChatBubbleColor?) {
        guard let db = clientDatabase else { return }
        Task { try? await db.pool.write { try ChatColors.setDefaultColor($0, c) } }
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
    /// Sends `text` to each chat (the share dialog).
    func sendText(_ text: String, to conversationIds: [String]) {
        guard let session = signalSession, !text.isEmpty else { return }
        let targets = conversationIds.compactMap { id in conversation(id) ?? composable.first { $0.id == id } }
        Task {
            for t in targets {
                do {
                    if t.kind == .group, let key = t.masterKey {
                        _ = try await session.messenger.sendGroupMessage(text, masterKey: key)
                    } else if let to = t.serviceId {
                        _ = try await session.messenger.sendMessage(text, attachments: [], to: to)
                    }
                } catch {
                    Self.trace("share failed: \(error)")
                }
            }
        }
    }

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

    func createNotificationProfile(_ p: NotificationProfile) {
        run("create notification profile") { _ = try await $0.messenger.createNotificationProfile(p) }
    }

    func updateNotificationProfile(_ p: NotificationProfile) {
        run("update notification profile") { try await $0.messenger.updateNotificationProfile(p) }
    }

    func deleteNotificationProfile(_ id: String) {
        run("delete notification profile") { try await $0.messenger.deleteNotificationProfile(id) }
    }

    func setNotificationProfileSyncEnabled(_ on: Bool, copyLabel: @escaping @Sendable (String) -> String) {
        run("notification profile sync") { try await $0.messenger.setNotificationProfileSyncEnabled(on, copyLabel: copyLabel) }
    }

    func notificationProfileSyncEnabled() async -> Bool {
        (try? await signalSession?.messenger.notificationProfileSyncEnabled()) ?? true
    }

    func notificationProfileOnboardingSeen() async -> Bool {
        (try? await clientDatabase?.notificationProfileOnboardingSeen()) ?? true
    }

    func setNotificationProfileOnboardingSeen() {
        run("profile onboarding seen") { try await $0.messenger.setNotificationProfileOnboardingSeen() }
    }

    func setNotificationProfileOverride(_ id: String, enabled: Bool, endsAt: Date?) {
        guard let session = signalSession else { return }
        let end = endsAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        Task {
            do { try await session.messenger.setNotificationProfileOverride(profileId: id, enabled: enabled, endsAt: end) } catch { Self.trace("profile override failed: \(error)") }
        }
    }
}

// Shared contacts (upstream EmbeddedContact, ContactDetail, SmartShareContactDialog,
// shareContact / enqueueSharedContactForSend): the card in a bubble, the detail panel it opens
// ("Message", calls, "Add to a group"), and the share dialog behind `desktop.shareContact.prod`.

import Foundation
import SignalCore
import SignalUI
import SwiftUI

@MainActor extension SignalSession {
    // MARK: the card and its panel

    /// `formatEmbeddedContactForUI` for the bubble: name, organization, avatar, and whether
    /// they can be messaged (`canMessageSharedContact`).
    func sharedContactCard(_ c: SharedContactInfo) -> SignalUI.SharedContact {
        var out = SignalUI.SharedContact(givenName: c.givenName, familyName: c.familyName, organization: c.organization)
        out.avatar = c.avatar.map { a in
            var v = SignalUI.MessageAttachment(contentType: a.contentType, fileName: nil, size: a.size, width: a.width, height: a.height)
            v.isDownloaded = a.isDownloaded
            v.pending = a.pending ?? false
            v.hasUrl = a.isDownloaded
            v.image = image(for: a)
            return v
        }
        out.canMessage = c.resolution != .notOnSignal
        return out
    }

    /// The detail view's numbers, emails, addresses, nickname and note.
    static func contactDetailFields(_ c: SharedContactInfo) -> ContactDetailFields {
        func form(_ type: Int) -> ContactDetailFields.FormType {
            switch type {
            case 2: .mobile
            case 3: .work
            case 4: .custom
            default: .home
            }
        }
        var f = ContactDetailFields()
        f.number = c.numbers.map { .init(form($0.type), $0.value, label: $0.label) }
        f.email = c.emails.map { .init(form($0.type), $0.value, label: $0.label) }
        f.address = c.addresses.map { a in
            ContactDetailFields.PostalAddress(type: a.type == 2 ? .work : a.type == 3 ? .custom : .home, label: a.label, street: a.street,
                                              pobox: a.pobox, neighborhood: a.neighborhood, city: a.city, region: a.region,
                                              postcode: a.postcode, country: a.country)
        }
        f.nicknameGiven = c.signalNicknameGiven
        f.nicknameFamily = c.signalNicknameFamily
        f.note = c.note
        return f
    }

    /// `openContactDetails`: the "ContactDetail" panel for the message's contact.
    func openSharedContact(_ m: TimelineMessage) {
        sharedContactMessage = m
        pushPanel("ContactDetail")
    }

    /// The panel's message, as the timeline now has it (its avatar's download status).
    var sharedContactShown: TimelineMessage? {
        guard let m = sharedContactMessage else { return nil }
        return messages.first { $0.id == m.id } ?? m
    }

    /// `lookupOrCreateConversationIdForSharedContact`, then `then` with their chat.
    func withSharedContactConversation(_ c: SharedContactInfo, _ then: @escaping @MainActor (_ id: String, _ serviceId: String?) -> Void) {
        guard let session else { return }
        Task {
            do {
                guard let found = try await session.messenger.conversation(forSharedContact: c) else { return Self.trace("shared contact: not on Signal") }
                then(found.id, found.serviceId)
            } catch {
                Self.trace("shared contact: lookup failed: \(error)")
            }
        }
    }

    /// `startConversationWithSharedContact` ("Message").
    func messageSharedContact(_ c: SharedContactInfo) {
        withSharedContactConversation(c) { [weak self] id, _ in Task { await self?.openNew(id) } }
    }

    /// The contact avatar's download (`kickOffAttachmentDownload` on a contact).
    func downloadContactAvatar(_ m: TimelineMessage) {
        guard let session, let a = m.contact?.avatar, !a.isDownloaded, !(a.pending ?? false) else { return }
        Task {
            do { try await session.downloads.requestDownload([.init(messageId: m.id, type: .contact, order: 0)]) } catch {
                Self.trace("contact avatar download failed: \(error)")
                toast = .attachmentDownloadFailed
            }
        }
    }

    // MARK: sharing

    /// `openShareContactDialog`: the contacts we may share, into the dialog.
    func openShareContactDialog() {
        guard let db = clientDatabase, let c = selectedConversation, let me = ourAci else { return }
        Task {
            do {
                let list = try await db.pool.read { db in try SharedContacts.candidates(db, excluding: c.id, ourAci: me) }
                // Their avatars, decoded ahead so a chosen contact's draft has its photo.
                for candidate in list { for option in candidate.avatarOptions { _ = avatarImage(option.file) } }
                shareContactRecipient = (c.id, c.title)
                shareContactCandidates = list
            } catch {
                Self.trace("share contact: candidates failed: \(error)")
            }
        }
    }

    func closeShareContactDialog() {
        shareContactCandidates = nil
        shareContactRecipient = nil
    }

    /// `getShareContactDraft` for the dialog.
    func shareContactDraft(_ conversationId: String) -> ShareContactDraft {
        shareContactPicked = conversationId
        guard let c = shareContactCandidates?.first(where: { $0.conversationId == conversationId }) else { return ShareContactDraft(aci: nil) }
        let d = c.draft
        let options = c.avatarOptions.map { ShareContactAvatar(image: avatarImage($0.file), isProfile: $0.isProfile) }
        let named = d.givenName != nil || d.familyName != nil
        let nicknamed = d.signalNicknameGiven != nil || d.signalNicknameFamily != nil
        return ShareContactDraft(aci: d.aci, avatar: options.first, avatarOptions: options,
                                 name: named ? EmbeddedContactName(givenName: d.givenName, familyName: d.familyName) : nil,
                                 e164: d.numbers.first?.value, organization: d.organization,
                                 nickname: nicknamed ? (d.signalNicknameGiven, d.signalNicknameFamily) : nil, note: d.note)
    }

    /// The dialog's contact as sent (`enqueueSharedContactForSend`): the number as one CUSTOM
    /// entry.
    static func sharedContactInfo(_ d: ShareContactDraft) -> SharedContactInfo {
        var info = SharedContactInfo(givenName: d.name?.givenName, familyName: d.name?.familyName)
        info.prefix = d.name?.prefix
        info.middleName = d.name?.middleName
        info.suffix = d.name?.suffix
        info.organization = d.organization
        info.numbers = d.e164.map { [.init(value: $0, type: 4)] } ?? []
        info.aci = d.aci
        info.signalNicknameGiven = d.nickname?.givenName
        info.signalNicknameFamily = d.nickname?.familyName
        info.note = d.note
        info.avatarIsProfile = d.avatar?.isProfile ?? false
        return info
    }

    /// `shareContact`: the safety-number review, then the contact (and the avatar shown, if
    /// any) sent to the chat the dialog was opened in.
    func shareContact(_ d: ShareContactDraft) {
        let picked = shareContactCandidates?.first { $0.conversationId == shareContactPicked }
        let recipient = shareContactRecipient
        closeShareContactDialog()
        guard let session, let recipient, let c = conversations.first(where: { $0.id == recipient.id }) ?? selectedConversation,
              c.id == recipient.id else { return }
        let info = Self.sharedContactInfo(d)
        let avatarFile = d.avatar.flatMap { a in picked?.avatarOptions.first { $0.isProfile == a.isProfile }?.file }
        let store = session.attachmentStore
        afterIdentityReview(conversationId: c.id, send: { Task {
            do {
                // copyAvatarForMessage: an unreadable avatar is left out, not the contact.
                let avatar = avatarFile.flatMap { file in try? store.plaintext(of: file) }.map(SharedContacts.avatarAttachment)
                if c.kind == .group {
                    guard let key = c.masterKey else { return Self.trace("share contact: group has no master key") }
                    _ = try await session.messenger.sendGroupMessage("", attachments: [], masterKey: key, contact: info, contactAvatar: avatar)
                } else {
                    guard let to = c.serviceId else { return Self.trace("share contact: no service id") }
                    _ = try await session.messenger.sendMessage("", attachments: [], to: to, contact: info, contactAvatar: avatar)
                }
                Self.trace("share contact: queued")
            } catch {
                Self.trace("share contact failed: \(error)")
            }
        } })
    }
}

/// The "ContactDetail" panel.
struct SharedContactPanel: View {
    @Bindable var session: SignalSession

    var body: some View {
        if let m = session.sharedContactShown, let c = m.contact {
            ContactDetail(contact: session.sharedContactCard(c), fields: SignalSession.contactDetailFields(c),
                          hasActiveCall: session.activeCall != nil,
                          onSendMessage: { session.messageSharedContact(c) },
                          onStartVideoCall: { session.withSharedContactConversation(c) { id, _ in session.openCallLobby(id, video: true) } },
                          onStartAudioCall: { session.withSharedContactConversation(c) { id, _ in session.openCallLobby(id, video: false) } },
                          onAddToGroup: { session.withSharedContactConversation(c) { _, sid in if let sid { session.showAddToGroup(sid) } } },
                          kickOffAttachmentDownload: { session.downloadContactAvatar(m) },
                          cancelAttachmentDownload: { session.cancelDownloads(m) })
        }
    }
}

/// The share-contact dialog while it is open.
struct ShareContactDialogHost: View {
    @Bindable var session: SignalSession

    var body: some View {
        if let list = session.shareContactCandidates {
            AxoBaseDialog.Host {
                ShareContactDialog(contacts: list.map { c in
                                       ShareContactCandidate(id: c.conversationId, title: c.title, color: c.color,
                                                             avatar: session.avatarImage(c.avatarOptions.first?.file), about: c.about)
                                   },
                                   recipientTitle: session.shareContactRecipient?.title ?? "", ourRegionCode: session.phoneRegion,
                                   getContactDraft: { session.shareContactDraft($0) },
                                   onClose: { session.closeShareContactDialog() },
                                   onShareContact: { session.shareContact($0) })
            }
        }
    }
}

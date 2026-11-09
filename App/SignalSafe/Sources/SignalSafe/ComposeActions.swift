// Compose's sub-screens (upstream LeftPaneMode ChooseGroupMembers, SetGroupMetadata,
// FindByUsername, FindByPhoneNumber): picking a new group's members, naming and creating it,
// and starting a chat with someone found by username or phone number.

import Foundation
import SignalCore
import SignalUI

enum ComposeMode { case compose, chooseGroupMembers, setGroupMetadata, findByUsername, findByPhoneNumber }

/// A lookup's error dialog text (a message key and its arguments).
struct ComposeError {
    var key: String
    var args: [String: String]
}

@MainActor extension SignalSession {
    func showComposeMode(_ mode: ComposeMode) {
        if !isComposing { startComposing() }
        composeMode = mode
        composeSearch = ""
    }

    /// `toggleConversationInChooseMembers`
    func toggleGroupMember(_ conversationId: String) {
        if let i = groupSelection.firstIndex(of: conversationId) { groupSelection.remove(at: i) } else { groupSelection.append(conversationId) }
    }

    /// `createGroup`: the group with the chosen members, then its chat opens.
    func createGroup() {
        guard let session = signalSession, let db = clientDatabase, !isCreatingGroup else { return }
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let members = groupSelection.compactMap { id in composable.first { $0.id == id }?.serviceId }
        let timer = newGroupTimer
        let avatar = newGroupAvatar, photo = newGroupPhoto
        isCreatingGroup = true
        Task {
            defer { isCreatingGroup = false }
            do {
                var bytes: Data?
                if let avatar { bytes = try await avatarBytes(avatar, photo: photo) }
                let keys = try await session.groups.create(title: name, avatar: bytes, expireTimer: timer > 0 ? timer : nil, members: members)
                let id = try await db.pool.write { try GroupStore.conversation($0, keys: keys).conversationId }
                await openNew(id)
            } catch {
                Self.trace("create group failed: \(error)")
                composeError = ComposeError(key: "icu:error", args: [:])
            }
        }
    }

    /// `lookupConversationWithoutServiceId` (username): the account, then its chat.
    func lookUpUsername(_ raw: String) {
        let username = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard let session = signalSession, !username.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        Task {
            defer { isLookingUp = false }
            do {
                guard let aci = try await session.usernames.lookUp(username) else {
                    composeError = ComposeError(key: "icu:startConversation--username-not-found", args: ["atUsername": "@\(username)"])
                    return
                }
                let id = try await session.messenger.directConversation(serviceId: aci, username: username)
                Task.detached { _ = try? await session.profiles.fetch(aci) }
                await openNew(id)
            } catch UsernameError.invalid {
                composeError = ComposeError(key: "icu:startConversation--username-not-valid", args: ["atUsername": "@\(username)"])
            } catch {
                Self.trace("username lookup failed: \(error)")
                composeError = ComposeError(key: "icu:startConversation--username-not-found", args: ["atUsername": "@\(username)"])
            }
        }
    }

    /// `lookupConversationWithoutServiceId` (phone number): CDSI, then its chat.
    func lookUpPhoneNumber(_ p: ParsedPhoneNumber) {
        guard let session = signalSession, !isLookingUp else { return }
        guard p.isValid else {
            composeError = ComposeError(key: "icu:startConversation--phone-number-not-valid", args: ["phoneNumber": p.userInput])
            return
        }
        isLookingUp = true
        Task {
            defer { isLookingUp = false }
            do {
                let entries = try await session.discovery.lookup(e164s: [p.e164])
                guard let serviceId = entries.first(where: { $0.e164 == p.e164 }).flatMap({ $0.aci ?? $0.pni }) else {
                    composeError = ComposeError(key: "icu:startConversation--phone-number-not-found", args: ["phoneNumber": p.userInput])
                    return
                }
                let id = try await session.messenger.directConversation(serviceId: serviceId, e164: p.e164)
                if !serviceId.hasPrefix("PNI:") { Task.detached { _ = try? await session.profiles.fetch(serviceId) } }
                await openNew(id)
            } catch {
                Self.trace("phone lookup failed: \(error)")
                composeError = ComposeError(key: "icu:startConversation--phone-number-not-found", args: ["phoneNumber": p.userInput])
            }
        }
    }

    /// Opens a chat that may be in neither the inbox nor compose yet (no messages, a stranger).
    func openNew(_ id: String) async {
        if let db = clientDatabase, let c = try? await db.pool.read({ try ConversationQueries.conversation($0, id: id) }) { opened = c }
        stopComposing()
        selectedConversationId = id
    }

    /// The region for parsing numbers typed without a country code: ours, else the Mac's.
    var phoneRegion: String { Locale.current.region?.identifier ?? "US" }
}


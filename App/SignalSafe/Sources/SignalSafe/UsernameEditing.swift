// Setting, changing and deleting our username (ts/state/ducks/username.preload.ts over
// SignalCore's UsernameService): UsernameEditor reserves as the nickname is typed (the newest
// request wins), confirms the reservation, and closes when it is saved; the profile editor
// deletes it. The onboarding banner and dialog (UsernameMegaphone, UsernameOnboardingModal)
// lead to the editor, and `signal.me` links open the chat they name.

import LibSignalClient
import Foundation
import SignalCore
import SignalUI

/// UsernameEditor's state (`UsernameStateType`).
struct UsernameEditing {
    var reservation: UsernameReservation?
    var previousUsername: String?
    var state: UsernameReservationState = .open
    var error: UsernameReservationError?
    /// The nickname length limits (`global.nicknames.min` / `max`).
    var nicknameLengths: ClosedRange<Int> = 3...32
}

extension SignalSession {
    /// `openUsernameReservationModal`: a fresh editor.
    func openUsernameEditor() {
        usernameReserveTask?.cancel()
        usernameEditing = UsernameEditing(previousUsername: accountSettings.username)
        guard let session else { return }
        Task { [weak self] in
            if let lengths = try? await session.usernames.nicknameLimits() { self?.usernameEditing.nicknameLengths = Int(lengths.lowerBound)...Int(lengths.upperBound) }
        }
    }

    /// `reserveUsername`: after a short pause in typing; a newer request replaces this one.
    func reserveUsername(nickname: String, discriminator: String?) {
        guard let session else { return }
        usernameReserveTask?.cancel()
        usernameEditing.error = nil
        usernameEditing.state = .reserving
        usernameReserveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                let reservation = try await session.usernames.reserve(nickname: nickname, discriminator: discriminator)
                guard !Task.isCancelled, let self else { return }
                self.usernameEditing.reservation = reservation
                self.usernameEditing.state = .open
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.usernameEditing.reservation = nil
                self.usernameEditing.error = Self.reservationError(error)
                self.usernameEditing.state = .open
            }
        }
    }

    /// The editor's message for a failed reservation (`reserveUsername`'s error mapping).
    static func reservationError(_ error: Error) -> UsernameReservationError {
        guard case UsernameError.reserve(let reason) = error else {
            if case UsernameError.invalid = error { return .checkCharacters }
            return .general
        }
        switch reason {
        case .unprocessable, .checkCharacters: return .checkCharacters
        case .conflict: return .usernameNotAvailable
        case .notEnoughCharacters: return .notEnoughCharacters
        case .tooManyCharacters: return .tooManyCharacters
        case .checkStartingCharacter: return .checkStartingCharacter
        case .notEnoughDiscriminator: return .notEnoughDiscriminator
        case .allZeroDiscriminator: return .allZeroDiscriminator
        case .leadingZeroDiscriminator: return .leadingZeroDiscriminator
        case .tooManyAttempts: return .tooManyAttempts
        }
    }

    func clearUsernameReservation() {
        usernameReserveTask?.cancel()
        usernameEditing.reservation = nil
        usernameEditing.error = nil
        usernameEditing.state = .open
    }

    /// `confirmUsername`: claims the reservation; the editor closes on success.
    func confirmUsername() {
        guard let session, let reservation = usernameEditing.reservation, usernameEditing.state == .open else { return }
        usernameEditing.state = .confirming
        Task { [weak self] in
            do {
                _ = try await session.usernames.confirm(reservation)
                self?.usernameEditing.state = .closed
            } catch {
                Self.trace("confirming username failed: \(error)")
                guard let self else { return }
                self.usernameEditing.state = .open
                // `ConfirmUsernameResult.ConflictOrGone`: the reservation lapsed or was taken.
                if case SignalError.usernameReservationNotFound = error { self.usernameEditing.error = .conflictOrGone }
                else if case SignalError.usernameNotAvailable = error { self.usernameEditing.error = .conflictOrGone }
                else if case SignalError.rateLimitedError = error { self.usernameEditing.error = .tooManyAttempts }
                else { self.usernameEditing.error = .general }
            }
        }
    }

    /// `deleteUsername`; `done` once it is gone (or failed).
    func deleteUsername(done: @escaping @MainActor () -> Void) {
        guard let session else { return done() }
        Task {
            do { try await session.usernames.delete() } catch {
                Self.trace("deleting username failed: \(error)")
                toast = .failedToDeleteUsername
            }
            done()
        }
    }

    /// The profile editor's username link tooltip and the onboarding banner, once seen.
    func markUsernameLinkOnboardingComplete() {
        guard let session else { return }
        Task { try? await session.messenger.setUsernameLinkOnboardingCompleted() }
    }

    /// `hasCompletedUsernameOnboarding` (synced to our other devices).
    func markUsernameOnboardingComplete() {
        guard let session else { return }
        Task { try? await session.messenger.setUsernameOnboardingCompleted() }
    }

    /// `signal.me` links: `#p/+…` a phone number, `#eu/…` a username link; each opens its chat
    /// (`showConversationViaSignalDotMe`). True when the link is one.
    func openSignalMeLink(_ url: URL) -> Bool {
        guard url.scheme == "https" || url.scheme == "sgnl", url.host == "signal.me", let fragment = url.fragment else { return false }
        if fragment.hasPrefix("p/") {
            let number = String(fragment.dropFirst(2))
            let valid = number.hasPrefix("+") && number.dropFirst().allSatisfy(\.isNumber) && (8...16).contains(number.count)
            lookUpPhoneNumber(ParsedPhoneNumber(isValid: valid, userInput: number, e164: number))
            return true
        }
        guard fragment.hasPrefix("eu/"), let session else {
            composeError = ComposeError(key: "icu:unknown-sgnl-link", args: [:])
            return true
        }
        Task {
            if let username = try? await session.usernames.lookUp(link: url) {
                lookUpUsername(username)
            } else {
                composeError = ComposeError(key: "icu:unknown-sgnl-link", args: [:])
            }
        }
        return true
    }
}

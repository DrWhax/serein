// The safety-number review that stands between a changed identity key and a send
// (upstream blockSendUntilConversationsAreVerified, conversationStoppedByMissingVerification
// and verifyConversationsStoppingSend, shown in SafetyNumberChangeDialog).
//
// SignalCore's identity store already refuses to encrypt to a key the user has not approved;
// this is the asking: before the composer sends, and whenever any other send stopped for it.

import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// One open review: the contacts whose safety number changed, and what the answer does.
@MainActor struct IdentityReview: Identifiable {
    let id = UUID()
    var contacts: [SafetyNumberChangeContact]
    var numbers: [String: SignalUI.SafetyNumber]
    var serviceIds: [String]
    /// Runs after the identities were approved ("Send anyway").
    var confirmed: @MainActor () -> Void
    var cancelled: @MainActor () -> Void
}

@MainActor extension SignalSession {
    /// Runs `send` right away when nobody in the conversation needs approval; otherwise only
    /// after the user confirmed in the dialog (`cancelled` when they did not).
    func afterIdentityReview(conversationId: String, send: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void = {}) {
        guard let session = signalSession else { return }
        Task {
            let pending: [String]
            do { pending = try await session.messenger.identitiesNeedingApproval(conversationId: conversationId) } catch {
                // Not knowing is no reason to skip the question: the store still decides.
                Self.trace("identity check failed: \(error)")
                pending = []
            }
            if pending.isEmpty { send() } else { await review(pending, confirmed: send, cancelled: cancelled) }
        }
    }

    /// Opens the dialog for `serviceIds` (merging into an open one for the same people).
    func review(_ serviceIds: [String], confirmed: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void = {}) async {
        guard let session = signalSession, !serviceIds.isEmpty else { return }
        if var open = identityReview, Set(open.serviceIds) == Set(serviceIds) {
            let (first, firstCancel) = (open.confirmed, open.cancelled)
            open.confirmed = { first(); confirmed() }
            open.cancelled = { firstCancel(); cancelled() }
            identityReview = open
            return
        }
        var numbers: [String: SignalUI.SafetyNumber] = [:]
        for id in serviceIds {
            if let n = try? await session.messenger.safetyNumber(with: id) {
                numbers[id] = SignalUI.SafetyNumber(numberBlocks: n.numberBlocks, qrData: Array(n.qrData))
            }
        }
        let contacts = serviceIds.map { id in
            let info = self.contacts[id]
            return SafetyNumberChangeContact(id: id, title: info?.title ?? id, color: info?.color ?? "A200", avatar: avatarImage(info?.avatar),
                                             hasName: info != nil, serviceId: id)
        }
        identityReview = IdentityReview(contacts: contacts, numbers: numbers, serviceIds: serviceIds, confirmed: confirmed, cancelled: cancelled)
    }

    /// "Send anyway": approve the keys on record, then let the waiting sends go.
    func confirmIdentityReview() {
        guard let review = identityReview, let session = signalSession else { return }
        identityReview = nil
        Task {
            do {
                try await session.messenger.approveIdentities(review.serviceIds)
                review.confirmed()
            } catch {
                Self.trace("identity approval failed: \(error)")
                review.cancelled()
            }
        }
    }

    func cancelIdentityReview() {
        guard let review = identityReview else { return }
        identityReview = nil
        review.cancelled()
    }

    /// Sends that stopped inside SignalCore for an untrusted identity (forwards, voice notes,
    /// retries, reactions…): ask, and on "Send anyway" retry the message that failed.
    func observeIdentityStops(_ session: SignalClient.Session) -> Task<Void, Never> {
        Task { [weak self] in
            for await stop in session.messenger.identityStops {
                Self.trace("send stopped: \(stop.serviceIds.count) identities need approval")
                await self?.review(stop.serviceIds, confirmed: { [weak self] in
                    if let id = stop.messageId { self?.retrySend(id) }
                })
            }
        }
    }
}

struct IdentityReviewDialog: View {
    @Bindable var session: SignalSession
    let review: IdentityReview

    var body: some View {
        AxoBaseDialog.Host {
            SafetyNumberChangeDialog(sections: [SafetyNumberChangeSection(contacts: review.contacts)],
                                     onCancel: { session.cancelIdentityReview() },
                                     onConfirm: { session.confirmIdentityReview() }) { contactId, onClose in
                SafetyNumberViewer(contactTitle: review.contacts.first { $0.id == contactId }?.title ?? contactId, isVerified: false,
                                   safetyNumber: review.numbers[contactId], verificationDisabled: true, onClose: onClose)
            }
        }
    }
}

/// One contact's safety number, opened from the "safety number changed" notice.
struct SafetyNumberSheet {
    var serviceId: String
    var title: String
    var number: SignalUI.SafetyNumber?
    var isVerified: Bool
}

@MainActor extension SignalSession {
    /// `toggleSafetyNumberModal`
    func showSafetyNumber(_ serviceId: String?) {
        guard let serviceId, let session = signalSession else { return }
        let title = contactTitle(serviceId)
        Task {
            let number = try? await session.messenger.safetyNumber(with: serviceId)
            let verified = (try? await session.messenger.verifiedStatus(serviceId)) == .verified
            safetyNumberSheet = SafetyNumberSheet(serviceId: serviceId, title: title,
                                                  number: number.map { SignalUI.SafetyNumber(numberBlocks: $0.numberBlocks, qrData: Array($0.qrData)) },
                                                  isVerified: verified)
        }
    }

    /// `toggleVerified`: marks the key on record as verified, or back to the default state.
    func toggleVerified() {
        guard let sheet = safetyNumberSheet, let session = signalSession else { return }
        Task {
            do {
                try await session.messenger.setVerified(sheet.serviceId, !sheet.isVerified)
                if safetyNumberSheet?.serviceId == sheet.serviceId { safetyNumberSheet?.isVerified = !sheet.isVerified }
            } catch {
                Self.trace("verification change failed: \(error)")
            }
        }
    }
}

struct SafetyNumberSheetDialog: View {
    @Bindable var session: SignalSession
    let sheet: SafetyNumberSheet
    let i18n: Localizer

    var body: some View {
        AxoBaseDialog.Host {
            AxoDialog.Content(size: .md, hasFooter: false) {
                AxoDialog.Header {
                    AxoDialog.Title(i18n("icu:SafetyNumberModal__title"))
                    AxoDialog.Close { session.safetyNumberSheet = nil }
                }
                AxoDialog.Body(maxHeight: 560) {
                    SafetyNumberViewer(contactTitle: sheet.title, isVerified: sheet.isVerified, safetyNumber: sheet.number,
                                       verificationDisabled: sheet.number == nil, toggleVerified: { session.toggleVerified() },
                                       onClose: { session.safetyNumberSheet = nil })
                }
            }
        }
    }
}

// The account-wide settings the Preferences pages show (the items upstream's AccountRecord
// carries): read live from the database, saved back to the items and the storage service.

import Foundation
import GRDB

public struct AccountSettings: Sendable, Equatable {
    public var phoneNumber: String?
    public var deviceId: UInt32 = 0
    public var readReceipts = false
    public var typingIndicators = false
    public var linkPreviews = false
    public var sealedSenderIndicators = false
    /// Seconds; 0 is off.
    public var universalExpireTimer = 0
    public var blockedContacts = 0
    public var blockedGroups = 0
    public var username: String?
    /// https://signal.me/#eu/… (the username link QR card).
    public var usernameLink: String?
    /// Settings → Calls (local to this device, as upstream): incoming call notifications, the
    /// ringtone, and always relaying calls (hides the IP address from the other side).
    public var incomingCallNotification = true
    public var callRingtoneNotification = true
    public var alwaysRelayCalls = false
    /// Settings → Data usage (local to this device, as upstream): which received attachments
    /// download without asking (`auto-download-attachment`), and whether images go out in high
    /// quality unless the composer's HD button says otherwise (`sent-media-quality`).
    public var autoDownload = AttachmentPolicy.AutoDownload()
    public var sentMediaQuality = SentMediaQuality.standard
    /// Settings → Privacy → Phone number (synced; changed through ProfileWriter, which talks
    /// to the server first, so `save` leaves them alone). Defaults as upstream's page shows them.
    public var sharesPhoneNumber = false
    public var discoverableByPhoneNumber = false
    /// Stories (AccountRecord): view receipts (unset follows read receipts) and stories off.
    public var storyViewReceipts = false
    public var storiesDisabled = false

    public init() {}

    public static func load(_ db: Database) throws -> AccountSettings {
        var s = AccountSettings()
        if let account = try Account.load(db) {
            s.phoneNumber = account.number
            s.deviceId = account.deviceId
        }
        s.readReceipts = try Items.get(db, "read-receipt-setting", as: Bool.self) ?? false
        s.typingIndicators = try Items.get(db, "typingIndicators", as: Bool.self) ?? false
        s.linkPreviews = try Items.get(db, "linkPreviews", as: Bool.self) ?? false
        s.sealedSenderIndicators = try Items.get(db, "sealedSenderIndicators", as: Bool.self) ?? false
        s.universalExpireTimer = try Items.get(db, "universalExpireTimer", as: Int.self) ?? 0
        s.incomingCallNotification = try Items.get(db, "incoming-call-notification", as: Bool.self) ?? true
        s.callRingtoneNotification = try Items.get(db, "call-ringtone-notification", as: Bool.self) ?? true
        s.alwaysRelayCalls = try Items.get(db, "always-relay-calls", as: Bool.self) ?? false
        s.autoDownload = try AttachmentPolicy.autoDownload(db)
        s.sentMediaQuality = try Items.get(db, "sent-media-quality", as: String.self).flatMap(SentMediaQuality.init) ?? .standard
        s.sharesPhoneNumber = try Items.get(db, "phoneNumberSharingMode", as: String.self) == "Everybody"
        s.discoverableByPhoneNumber = try Items.get(db, "phoneNumberDiscoverability", as: String.self) == "Discoverable"
        s.storyViewReceipts = try Items.get(db, "storyViewReceiptsEnabled", as: Bool.self) ?? s.readReceipts
        s.storiesDisabled = try Items.get(db, "hasStoriesDisabled", as: Bool.self) ?? false
        s.blockedContacts = Set(try BlockedList.serviceIds.entries(db).map(\.id)).union(try BlockedList.numbers.entries(db).map(\.id)).count
        s.blockedGroups = try BlockedList.groups.entries(db).count
        s.username = try Items.get(db, "username", as: String.self)
        if let link = try Items.get(db, "usernameLink", as: StorageRecords.UsernameLink.self),
           let entropy = Data(base64Encoded: link.entropy), let server = Data(base64Encoded: link.serverId), server.count == 16 {
            let handle = UUID(uuid: (server[0], server[1], server[2], server[3], server[4], server[5], server[6], server[7],
                                     server[8], server[9], server[10], server[11], server[12], server[13], server[14], server[15]))
            s.usernameLink = UsernameService.linkURL(entropy: entropy, handle: handle).absoluteString
        }
        return s
    }

    /// Writes the changeable settings and schedules the AccountRecord upload.
    public func save(_ db: Database) throws {
        try Items.set(db, "read-receipt-setting", readReceipts)
        try Items.set(db, "typingIndicators", typingIndicators)
        try Items.set(db, "linkPreviews", linkPreviews)
        try Items.set(db, "sealedSenderIndicators", sealedSenderIndicators)
        try Items.set(db, "universalExpireTimer", universalExpireTimer)
        try Items.set(db, "incoming-call-notification", incomingCallNotification)
        try Items.set(db, "call-ringtone-notification", callRingtoneNotification)
        try Items.set(db, "always-relay-calls", alwaysRelayCalls)
        try Items.set(db, "auto-download-attachment", autoDownload)
        try Items.set(db, "sent-media-quality", sentMediaQuality.rawValue)
        if let account = try Account.load(db) { try StorageWriteBack.accountChanged(db, account: account) }
    }
}

/// `SentMediaQualitySettingType`
public enum SentMediaQuality: String, Sendable, CaseIterable {
    case standard, high
}

extension SignalDatabase {
    /// The account entropy pool (Settings → Account → Signal account keys); read on demand,
    /// after the OS authentication prompt, never kept in view state.
    public func accountEntropyPool() async throws -> String? { try await pool.read { try Items.get($0, "accountEntropyPool", as: String.self) } }

    public func accountSettingsUpdates() -> AsyncThrowingStream<AccountSettings, Error> { observe(AccountSettings.load) }

    public func saveAccountSettings(_ s: AccountSettings) async throws { try await pool.write { try s.save($0) } }
}

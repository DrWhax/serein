// Settings → Data usage: the `auto-download-attachment` and `sent-media-quality` items, with
// upstream's defaults (everything downloads, standard quality), saved and read back, and the
// download policy following them.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct DataUsageSettingsTests {
    @Test func defaultsSaveAndPolicy() async throws {
        let (database, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = try await database.pool.read { try AccountSettings.load($0) }
        #expect(defaults.autoDownload == AttachmentPolicy.AutoDownload() && defaults.sentMediaQuality == .standard)

        var s = defaults
        s.autoDownload.videos = false
        s.autoDownload.documents = false
        s.sentMediaQuality = .high
        try await database.saveAccountSettings(s)
        let (loaded, policy, raw) = try await database.pool.read { db in
            (try AccountSettings.load(db), try AttachmentPolicy.autoDownload(db),
             try String.fetchOne(db, sql: "SELECT json FROM items WHERE id = 'sent-media-quality'"))
        }
        #expect(loaded.autoDownload == s.autoDownload && loaded.sentMediaQuality == .high)
        #expect(policy.photos && !policy.videos && policy.audio && !policy.documents)
        #expect(raw?.contains("\"high\"") == true)   // the string upstream stores

        let video = MessageAttachment(contentType: "video/mp4", size: 1000)
        #expect(!AttachmentPolicy.shouldAutoDownload(video, type: .attachment, settings: policy, maxAutoDownload: 1 << 20))
    }
}

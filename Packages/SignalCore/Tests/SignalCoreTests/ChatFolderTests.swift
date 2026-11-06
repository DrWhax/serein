// Chat folders: membership rules (isConversationInChatFolder) and the store (positions,
// toggles, tombstones, storage queueing).

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct ChatFolderTests {
    @Test func membership() {
        let direct = ChatFolderConversation(id: "d", isGroup: false)
        let group = ChatFolderConversation(id: "g", isGroup: true, muteExpiresAt: 5, unreadCount: 2)
        let all = ChatFolder(folderType: .all, name: "")
        #expect(ChatFolderStore.contains(all, direct) && ChatFolderStore.contains(all, group))
        var individuals = ChatFolder(name: "People", includeAllIndividualChats: true)
        #expect(ChatFolderStore.contains(individuals, direct) && !ChatFolderStore.contains(individuals, group))
        individuals.excludedConversationIds = ["d"]
        #expect(!ChatFolderStore.contains(individuals, direct))
        var groups = ChatFolder(name: "Groups", includeAllGroupChats: true)
        #expect(ChatFolderStore.contains(groups, group))
        groups.showMutedChats = false
        #expect(!ChatFolderStore.contains(groups, group) && ChatFolderStore.contains(groups, group, ignoreShowMutedChats: true))
        let unread = ChatFolder(name: "Unread", showOnlyUnread: true, includeAllIndividualChats: true, includeAllGroupChats: true)
        #expect(ChatFolderStore.contains(unread, group) && !ChatFolderStore.contains(unread, direct))
        #expect(ChatFolderStore.contains(unread, ChatFolderConversation(id: "m", isGroup: false, markedUnread: true)))
        let picked = ChatFolder(name: "Picked", includedConversationIds: ["d"])
        #expect(ChatFolderStore.contains(picked, direct) && !ChatFolderStore.contains(picked, group))
    }

    @Test func storeKeepsOrderAndTombstones() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        try await database.pool.write { db in
            let work = try ChatFolderStore.create(db, ChatFolder(name: "Work and everything else that is way too long", includeAllGroupChats: true))
            #expect(work.name.count == ChatFolder.nameMaxLength)
            let family = try ChatFolderStore.create(db, ChatFolder(name: "Family"))
            let all = try ChatFolderStore.ensureAllChats(db)
            #expect(try ChatFolderStore.current(db).map(\.id) == [all.id, work.id, family.id])
            try ChatFolderStore.toggle(db, folderId: family.id, conversationId: "c1", included: true)
            try ChatFolderStore.toggle(db, folderId: work.id, conversationId: "c1", included: false)
            #expect(try ChatFolderStore.get(db, id: family.id)?.includedConversationIds == ["c1"])
            #expect(try ChatFolderStore.get(db, id: work.id)?.excludedConversationIds == ["c1"])
            try ChatFolderStore.reorder(db, ids: [all.id, family.id, work.id])
            #expect(try ChatFolderStore.current(db).map(\.name) == ["", "Family", work.name])
            try ChatFolderStore.delete(db, id: family.id, at: 1_000)
            #expect(try ChatFolderStore.current(db).map(\.id) == [all.id, work.id])
            #expect(try ChatFolderStore.get(db, id: family.id)?.position == ChatFolder.deletedPosition)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatFolders WHERE storageNeedsSync = 1") == 3)
            #expect(try ChatFolderStore.deleteExpired(db, messageQueueTime: 500, now: 2_000) == [family.id])
        }
    }
}

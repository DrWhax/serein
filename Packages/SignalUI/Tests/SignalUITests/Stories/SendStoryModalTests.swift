// SendStoryModal stories (ts/components/SendStoryModal.dom.stories.tsx): the "Send to" page,
// full-viewport portal captures, with the story's "hello" text attachment. Me, the group
// stories and the custom lists (random test-helper data) are read back from each capture's DOM.

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct SendStoryModalTests {
    static let draft = StoryAttachmentData(contentType: "text/x-signal-story",
                                           textAttachment: TextAttachmentData(text: "hello", textStyle: .regular, textForegroundColor: 4_294_967_295,
                                                                              textBackgroundColor: 4_293_263_387, color: 4_286_869_806))

    static func modal(_ story: String, _ theme: String) -> SendStoryModal {
        let dom = StoryDOM("components-sendstorymodal--\(story)", theme: theme)
        let rows = dom.groups(startingWith: "SendStoryModal__distribution-list").filter { $0[0].cls == "SendStoryModal__distribution-list" }
        func name(_ row: [StoryDOM.Node]) -> String { row.first { $0.tag == "span" && $0.cls.isEmpty && $0.text != nil }?.text ?? "" }
        func count(_ row: [StoryDOM.Node]) -> Int {
            Int(row.filter { $0.cls == "SendStoryModal__rtl-span" }.last?.text?.split(separator: " ").first ?? "") ?? 0
        }
        func members(_ n: Int) -> [SearchableConversation] {
            (0..<n).map { i in
                var c = SearchableConversation(listItem: ContactListItemData(id: "m\(i)", title: "Member \(i)"))
                c.serviceId = "aci-\(i)"
                return c
            }
        }
        let me = rows.first.map { StoriesSettingsModalTests.avatarData($0, title: "Me", type: .direct) } ?? ConversationAvatarData(title: "Me")
        var myStory = StoryDistributionList(id: MyStoryList.myStoryId, name: MyStoryList.myStoryId, isBlockList: true)
        switch story {
        case "block-list": myStory.members = members(1)
        case "allow-list":
            myStory.isBlockList = false
            myStory.members = members(1)
        case "first-time-already-configured-on-mobile":
            myStory.isBlockList = false
            myStory.members = members(3)
        default: break
        }
        var groups: [GroupStoryInfo] = []
        var lists = story == "announcements-only" ? [] : [myStory]
        for (i, row) in rows.enumerated().dropFirst() {
            if row.contains(where: { $0.cls == "StoriesSettingsModal__list__avatar--custom" }) {
                lists.append(StoryDistributionList(id: "l\(i)", name: name(row), isBlockList: false, members: members(count(row))))
            } else {
                groups.append(GroupStoryInfo(id: "g\(i)", title: name(row), avatar: StoriesSettingsModalTests.avatarData(row, title: name(row), type: .group),
                                             membersCount: count(row)))
            }
        }
        return SendStoryModal(draftAttachment: draft, candidateConversations: [], distributionLists: lists, groupConversations: [], groupStories: groups,
                              hasFirstStoryPostExperience: story.hasPrefix("first-time"), me: me, signalConnections: members(42))
    }

    @Test(arguments: ["modal", "block-list", "allow-list", "first-time", "first-time-already-configured-on-mobile", "announcements-only"],
          ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.modal(name, theme), story: "components-sendstorymodal--\(name)", theme: theme)
    }
}

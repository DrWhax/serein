// StoriesSettingsModal stories (ts/components/StoriesSettingsModal.dom.stories.tsx): the
// "Story privacy" list page, full-viewport portal captures. `me`, the group stories and the
// custom list (getDefaultConversation / getDefaultGroup / getFakeDistributionList) are read
// back from each capture's DOM.

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct StoriesSettingsModalTests {
    static func avatarData(_ row: [StoryDOM.Node], title: String, type: AvatarConversationType) -> ConversationAvatarData {
        let color = CallingAdhocCallInfoTests.colorName(row.first { $0.cls.split(separator: " ").contains("module-Avatar__contents") }?.style["color"])
        let image = row.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        return ConversationAvatarData(title: title, conversationType: type, color: color, image: image, hasAvatar: image != nil)
    }

    static func member(_ i: Int) -> SearchableConversation {
        var c = SearchableConversation(listItem: ContactListItemData(id: "m\(i)", title: "Member \(i)"))
        c.serviceId = "aci-\(i)"
        return c
    }

    static func modal(_ story: String, _ theme: String) -> StoriesSettingsModal {
        let dom = StoryDOM("components-storiessettingsmodal--\(story)", theme: theme)
        let rows = dom.groups(startingWith: "StoriesSettingsModal__list").filter { $0[0].cls == "StoriesSettingsModal__list" }
        func title(_ row: [StoryDOM.Node]) -> String { row.first { $0.tag == "span" && $0.cls.isEmpty && $0.text != nil }?.text ?? "" }
        func count(_ row: [StoryDOM.Node]) -> Int {
            let text = row.first { $0.cls == "StoriesSettingsModal__list__viewers" }?.text ?? ""
            return Int(text.split(separator: "\u{00A0}").last?.split(separator: " ").first ?? "") ?? 0
        }
        let me = avatarData(rows[1], title: "Me", type: .direct)
        let custom = story == "single-list" ? rows[2] : nil
        let groupRows = rows.dropFirst(custom == nil ? 2 : 3)
        let groups = groupRows.enumerated().map { i, row in
            GroupStoryInfo(id: "g\(i)", title: title(row), avatar: avatarData(row, title: title(row), type: .group), membersCount: count(row))
        }
        var myStory = StoryDistributionList(id: MyStoryList.myStoryId, name: "", isBlockList: true)
        switch story {
        case "my-stories-block-list": myStory.members = (0..<2).map(member)
        case "my-stories-exclusive":
            myStory.isBlockList = false
            myStory.members = (0..<11).map(member)
        default: break
        }
        var lists = [myStory]
        if let custom {
            lists.append(StoryDistributionList(id: "custom", name: title(custom), members: (0..<count(custom)).map(member)))
        }
        return StoriesSettingsModal(candidateConversations: [], distributionLists: lists, groupStories: groups, signalConnectionsCount: 42, me: me,
                                    storyViewReceiptsEnabled: false)
    }

    @Test(arguments: ["my-stories", "my-stories-block-list", "my-stories-exclusive", "single-list"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.modal(name, theme), story: "components-storiessettingsmodal--\(name)", theme: theme)
    }
}

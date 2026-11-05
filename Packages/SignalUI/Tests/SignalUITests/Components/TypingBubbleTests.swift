// TypingBubble stories (ts/components/conversation/TypingBubble.dom.stories.tsx), in their
// state after the stories' timeouts. The two badge stories wait for Avatar badges.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TypingBubbleTests {
    /// CONTACTS: "A A" … "J J", coloured AvatarColors[index].
    static func contacts(_ indices: [Int]) -> [TypingContact] {
        indices.map { i in
            let letter = String(UnicodeScalar(UInt8(65 + i)))
            return TypingContact(id: "contact-\(i)", title: "\(letter) \(letter)", color: AxoTokens.Avatar.allColorNames[i])
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let cases: [(String, TypingBubble.ConversationType, [Int])] = [
            ("direct", .direct, [0]), ("group", .group, [0]), ("group-starts-typing", .group, [0]), ("group-multi-typing-1-to-2", .group, [0, 1]),
            ("group-multi-typing-2-then-1-person-stops", .group, [0]), ("group-multi-typing-3-to-4", .group, [0, 1, 2, 3]),
            ("group-multi-typing-10", .group, Array(0..<10)),
        ]
        for (name, type, typists) in cases {
            try Snapshot.assertMatches(TypingBubble(conversationType: type, typingContacts: Self.contacts(typists)),
                                       story: "components-conversation-typingbubble--\(name)", theme: theme)
        }
    }
}

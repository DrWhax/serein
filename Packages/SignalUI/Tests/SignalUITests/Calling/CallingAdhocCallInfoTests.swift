// CallingAdhocCallInfo stories. Avatar colours are `sample(AvatarColors)` per capture and
// unknown contacts' colours come from random service ids, so rows are read from the DOM.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingAdhocCallInfoTests {
    static func colorName(_ css: String?) -> String {
        let parts = (css ?? "").split { !$0.isNumber }.compactMap { Int($0) }
        guard parts.count >= 3 else { return "A100" }
        let hex = UInt32(parts[0] << 16 | parts[1] << 8 | parts[2])
        return AxoTokensTables.avatarColors.first { $0.fg == RGBA(hex: hex) }?.name ?? "A100"
    }

    /// An ACI whose last four hex digits pick avatar colour `name`.
    static func aci(for name: String, _ i: Int) -> String {
        let index = AxoTokensTables.avatarColors.firstIndex { $0.name == name } ?? 0
        let h = String(index, radix: 16)
        return "unknown-\(i)-" + String(repeating: "0", count: 4 - h.count) + h
    }

    static func participants(_ id: String, theme: String) -> [CallingParticipant] {
        var out: [CallingParticipant] = []
        for (i, nodes) in StoryDOM(id, theme: theme).groups(startingWith: "module-calling-participants-list__contact").enumerated() {
            let contents = nodes.filter { $0.cls.split(separator: " ").contains("module-Avatar__contents") }
            if nodes.contains(where: { $0.cls.contains("CallingAdhocCallInfo__UnknownContactAvatar") }) {
                let label = nodes.first { $0.cls.contains("module-calling-participants-list__name") }?.text ?? ""
                let count = Int(label.filter(\.isNumber)) ?? contents.count
                for k in 0..<count {
                    let color = colorName(contents[min(k, contents.count - 1)].style["color"])
                    out.append(CallingParticipant(conversation: CallingConversation(id: "u\(i)-\(k)", title: "Unknown Contact", aci: aci(for: color, k)),
                                                  isUnknownContact: true))
                }
                continue
            }
            let isMe = nodes.contains { $0.text == "You" }
            let title = isMe ? "My Name" : (nodes.first { $0.text != nil && !$0.text!.isEmpty && $0.text != "Presenting" }?.text ?? "")
            let c = CallingConversation(id: "p\(i)", title: title, color: colorName(contents.first?.style["color"]), aci: isMe ? "me" : "aci-\(i)")
            out.append(CallingParticipant(conversation: c, demuxId: UInt32(i), hasRemoteAudio: !nodes.contains { $0.cls.contains("__muted--audio") },
                                          presenting: nodes.contains { $0.text == "Presenting" },
                                          isInSystemContacts: nodes.contains { $0.cls.contains("__contact-icon") }))
        }
        return out
    }

    @Test(arguments: ["no-one", "solo-call", "many-participants", "overflow", "as-admin", "unknown-participants"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        let id = "components-callingadhoccallinfo--\(name)"
        let view = CallingAdhocCallInfo(participants: Self.participants(id, theme: theme), ourAci: "me", onClose: {}, onCopyCallLink: {},
                                        onShareCallLinkViaSignal: {})
        try Snapshot.assertMatches(view, story: id, theme: theme)
    }

    @Test func unknownContactColours() {
        #expect(CallingAdhocCallInfo.unknownColor("x-000c") == "A100")
        #expect(CallingAdhocCallInfo.unknownColor("x-0007") == "A170")
        #expect(CallingAdhocCallInfo.unknownColor(nil) == "A100")
    }
}

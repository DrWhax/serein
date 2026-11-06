// CallingParticipantMenu `Basic`: the dropdown and context-menu triggers (closed), force-dark.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingParticipantMenuTests {
    @Test(arguments: ["light", "dark"])
    func basic(theme: String) throws {
        var actions = CallingParticipantMenuActions()
        actions.onMuteAudio = {}
        actions.onViewProfile = {}
        actions.onGoToChat = {}
        actions.onBlockFromCall = {}
        actions.onRemoveFromCall = {}
        let view = menuContainer(HStack(spacing: 32) {
            CallingParticipantMenu(renderer: .dropdownMenu, participantTitle: "Participant Name", actions: actions) {
                AxoButton.Root("Open Dropdown Menu", variant: .strongSecondary, size: .md)
            }
            CallingParticipantMenu(renderer: .contextMenu, participantTitle: "Participant Name", actions: actions) {
                CSSText("Right-Click", type: .bodyLarge, wrap: .nowrap, color: .labelAccent).padding(48).background(AxoColor.fillPrimary)
            }
        })
        try Snapshot.assertMatches(view, story: "components-callingparticipantmenu--basic", theme: theme)
    }
}

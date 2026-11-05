// ChatSessionRefreshedDialog / DeliveryIssueDialog stories: the dialog opened over the
// story's AxoDialog.StoryTrigger (see AxoDialogTests' PortalStage).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ExplainerDialogTests {
    static func stage(_ dialog: some View) -> some View {
        PortalStage {
            AxoButton.Root("Open Dialog", variant: .strongPrimary, size: .md)
        } modal: {
            AxoBaseDialog.Host { dialog }
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-"
        try Snapshot.assertMatches(Self.stage(ChatSessionRefreshedDialog {}), story: c + "chatsessionrefresheddialog--default", theme: theme)
        try Snapshot.assertMatches(Self.stage(DeliveryIssueDialog(senderTitle: "Mattie Grady", inGroup: false) {}),
                                   story: c + "deliveryissuedialog--default", theme: theme)
        try Snapshot.assertMatches(Self.stage(DeliveryIssueDialog(senderTitle: "Mattie Grady", inGroup: true) {}),
                                   story: c + "deliveryissuedialog--in-group", theme: theme)
    }
}

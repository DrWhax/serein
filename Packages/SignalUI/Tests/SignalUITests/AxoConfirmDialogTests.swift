// AxoConfirmDialog stories (ts/axo/AxoConfirmDialog.dom.stories.tsx): open, no trigger.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AxoConfirmDialogTests {
    @Test(arguments: ["light", "dark"])
    func primary(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: "Save changes?", description: "Do you want to save the changes you’ve made to this chat folder?") {
                    AxoConfirmDialog.Cancel()
                    AxoConfirmDialog.Action("Save", variant: .strongPrimary) {}
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoconfirmdialog--primary", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func destructive(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: "Discard draft?", description: "This action can't be undone.") {
                    AxoConfirmDialog.Cancel()
                    AxoConfirmDialog.Action("Discard", variant: .strongDestructive) {}
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoconfirmdialog--destructive", theme: theme)
    }
}

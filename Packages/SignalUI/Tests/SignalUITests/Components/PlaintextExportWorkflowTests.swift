// PlaintextExportWorkflow stories (ts/components/PlaintextExportWorkflow.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PlaintextExportWorkflowTests {
    nonisolated static let steps: [String: PlaintextExportStep] = [
        "confirming-export": .confirmingExport,
        "confirming-with-os": .confirmingWithOS(includeMedia: true),
        "choosing-location": .choosingLocation(includeMedia: true),
        "exporting-messages": .exportingMessages(exportPath: "/somewhere"),
        "exporting-attachments": .exportingAttachments(exportPath: "/somewhere", totalBytes: 1_000_000, currentBytes: 500_000),
        "complete-mac": .complete(exportPath: "/somewhere"),
        "complete-linux": .complete(exportPath: "/somewhere"),
        "error-generic": .error(.general),
        "error-not-enough-storage": .error(.notEnoughStorage(bytesNeeded: 12_000_000)),
        "error-ran-out-of-storage": .error(.ranOutOfStorage(bytesNeeded: 12_000_000)),
        "error-storage-permissions": .error(.storagePermissions),
    ]

    @Test(arguments: Array(steps.keys).sorted(), ["light", "dark"])
    func story(name: String, theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                PlaintextExportWorkflow(workflow: Self.steps[name]!, osName: name == "complete-linux" ? .linux : .macos)
            }
        }
        try Snapshot.assertMatches(view, story: "components-plaintextexportworkflow--\(name)", theme: theme)
    }
}

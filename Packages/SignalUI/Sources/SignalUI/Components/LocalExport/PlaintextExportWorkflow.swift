// Port of ts/components/PlaintextExportWorkflow.dom.tsx (types/LocalExport): exporting the
// chat history as plaintext — confirm (with "Include media"), the OS confirmation and folder
// choice (Continue pending), the progress (indeterminate while messages export, bytes once
// attachments do), then done (show in Finder) or an error (general, not enough storage,
// ran out of storage, no permission).

import SignalI18n
import SwiftUI

/// `LocalExportErrorDetails`
public enum LocalExportError: Sendable, Hashable {
    case general
    case notEnoughStorage(bytesNeeded: Int)
    case ranOutOfStorage(bytesNeeded: Int)
    case storagePermissions
}

/// `PlaintextExportWorkflowType`
public enum PlaintextExportStep: Sendable, Hashable {
    case confirmingExport
    case confirmingWithOS(includeMedia: Bool)
    case choosingLocation(includeMedia: Bool)
    case exportingMessages(exportPath: String)
    case exportingAttachments(exportPath: String, totalBytes: Int, currentBytes: Int)
    case complete(exportPath: String)
    case error(LocalExportError)
}

public struct PlaintextExportWorkflow: View {
    public enum OSName: Sendable { case linux, macos, windows }
    let workflow: PlaintextExportStep
    let osName: OSName?
    let cancelWorkflow: () -> Void
    let clearWorkflow: () -> Void
    let openFileInFolder: (String) -> Void
    let verifyWithOSForExport: (Bool) -> Void
    @State private var includeMedia = true
    @Environment(\.i18n) var i18n

    public init(workflow: PlaintextExportStep, osName: OSName? = .macos, cancelWorkflow: @escaping () -> Void = {}, clearWorkflow: @escaping () -> Void = {},
                openFileInFolder: @escaping (String) -> Void = { _ in }, verifyWithOSForExport: @escaping (Bool) -> Void = { _ in }) {
        self.workflow = workflow
        self.osName = osName
        self.cancelWorkflow = cancelWorkflow
        self.clearWorkflow = clearWorkflow
        self.openFileInFolder = openFileInFolder
        self.verifyWithOSForExport = verifyWithOSForExport
    }

    var bold: [String: I18nTagStyle] { ["bold": I18nTagStyle(fontName: AxoFonts.interName(weight: 700))] }

    public var body: some View {
        switch workflow {
        case .confirmingExport, .confirmingWithOS, .choosingLocation: confirm
        case .exportingMessages: progress(nil)
        case .exportingAttachments(_, let total, let current): progress((total, current))
        case .complete(let path): complete(path)
        case .error(let e): error(e)
        }
    }

    var confirm: some View {
        let spinning: Bool = if case .confirmingExport = workflow { false } else { true }
        return AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    AxoDialog.BodyTitle(i18n("icu:PlaintextExport--Confirmation--Header"))     // its own mb-2.5
                    CSSText(runs: CSSTextRun.runs(i18n.richText("icu:PlaintextExport--Confirmation--Description"), tags: bold),
                            style: CSSTextStyle(AxoType.bodyMedium), color: .labelSecondary)
                        .padding(.bottom, 10)
                    HStack(spacing: 0) {
                        AxoCheckbox.Root(variant: .square, checked: $includeMedia, disabled: spinning, autoFocus: !spinning)
                        CSSText(runs: CSSTextRun.runs(i18n.richText("icu:PlaintextExport--Confirmation--IncludeMedia"),
                                                      tags: ["secondary": I18nTagStyle(color: .labelSecondary)]),
                                style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary)
                            .padding(.leading, 8)
                            .onTapGesture { if !spinning { includeMedia.toggle() } }
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, autoFocus: spinning, action: clearWorkflow)
                    AxoDialog.Action(i18n("icu:PlaintextExport--Confirmation--ContinueButton"), variant: .strongPrimary, pending: spinning) {
                        verifyWithOSForExport(includeMedia)
                    }
                }
            }
        }
    }

    func progress(_ bytes: (total: Int, current: Int)?) -> some View {
        let rtl = i18n.direction == .rightToLeft
        return AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    AxoDialog.BodyTitle(i18n("icu:PlaintextExport--ProgressDialog--Header"), alignment: .center)
                    VStack(spacing: 0) {
                        if let bytes {
                            let fraction = bytes.total > 0 ? Double(bytes.current) / Double(bytes.total) : 0
                            ProgressBar(fractionComplete: fraction, isRTL: rtl).padding(.bottom, 16)
                            CSSText(i18n("icu:PlaintextExport--ProgressDialog--Progress", [
                                "currentBytes": .string(formatFileSize(bytes.current)), "totalBytes": .string(formatFileSize(bytes.total)),
                                "percentage": .number(fraction),
                            ]), style: CSSTextStyle(AxoType.bodySmall.weight(600)), alignment: .center, color: .labelPrimary)
                                .padding(.bottom, 6)
                        } else {
                            ProgressBar(fractionComplete: nil, isRTL: rtl).padding(.bottom, 16)
                        }
                        CSSText(i18n("icu:PlaintextExport--ProgressDialog--TimeWarning"), style: CSSTextStyle(AxoType.bodySmall), alignment: .center,
                                color: .labelSecondary)
                    }
                    // my-6, its top margin collapsing with the title's 10px mb-2.5.
                    .padding(.top, 24 - 10).padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
            AxoDialog.Footer {
                AxoDialog.Actions(width: .fill) {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, autoFocus: true, action: cancelWorkflow)
                }
            }
        }
    }

    func complete(_ path: String) -> some View {
        let showKey = switch osName {
        case .macos: "icu:PlaintextExport--CompleteDialog--ShowFiles--Mac"
        case .linux: "icu:PlaintextExport--CompleteDialog--ShowFiles--Linux"
        default: "icu:PlaintextExport--CompleteDialog--ShowFiles--Windows"
        }
        return AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:PlaintextExport--CompleteDialog--Header"))
                AxoAlertDialog.Description(runs: CSSTextRun.runs(i18n.richText("icu:PlaintextExport--CompleteDialog--Description"), tags: bold))
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Action(i18n(showKey), variant: .subtleSecondary) { openFileInFolder(path) }
                AxoAlertDialog.Ok(action: clearWorkflow)
            }
        }
    }

    func error(_ e: LocalExportError) -> some View {
        let (title, detail): (String, String) = switch e {
        case .general: (i18n("icu:PlaintextExport--Error--General--Title"), i18n("icu:PlaintextExport--Error--General--Description"))
        case .notEnoughStorage(let n):
            (i18n("icu:PlaintextExport--Error--NotEnoughStorage--Title"),
             i18n("icu:PlaintextExport--Error--NotEnoughStorage--Detail", ["bytes": .string(formatFileSize(n))]))
        case .ranOutOfStorage(let n):
            (i18n("icu:PlaintextExport--Error--RanOutOfStorage--Title"),
             i18n("icu:PlaintextExport--Error--RanOutOfStorage--Detail", ["bytes": .string(formatFileSize(n))]))
        case .storagePermissions:
            (i18n("icu:PlaintextExport--Error--DiskPermssions--Title"), i18n("icu:PlaintextExport--Error--DiskPermssions--Detail"))
        }
        return AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(title)
                AxoAlertDialog.Description(detail)
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Ok(action: clearWorkflow)
            }
        }
    }
}

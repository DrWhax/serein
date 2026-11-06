// Port of ts/components/CallQualitySurveyDialog.dom.tsx: after a call, "How was your call?"
// (thumbs down / up), then for issues a picker of issue groups (Audio and Video expand into
// sub-issues; "Something else" asks for a description), then the confirmation with the
// optional debug log and the link to the diagnostic info.

import SignalI18n
import SwiftUI

/// `CallQualitySurvey.Issue`
public enum CallQualityIssue: String, Sendable, Hashable, CaseIterable {
    case audio, audioStuttering = "audio_stuttering", audioLocalEcho = "audio_local_echo", audioRemoteEcho = "audio_remote_echo"
    case audioDrop = "audio_drop", video, videoNoCamera = "video_no_camera", videoLowQuality = "video_low_quality"
    case videoLowResolution = "video_low_resolution", callDropped = "call_dropped", other

    var symbol: AxoSymbol.Name {
        switch self {
        case .audio, .audioStuttering, .audioLocalEcho, .audioRemoteEcho, .audioDrop: "speaker"
        case .video, .videoNoCamera, .videoLowQuality, .videoLowResolution: "videocamera"
        case .callDropped: "x-circle"
        case .other: "error-circle"
        }
    }

    var labelKey: String { "icu:CallQualitySurvey__Issue--\(rawValue.uppercased())" }

    /// `IssueGroups`: each parent and the sub-issues it reveals when selected.
    static let groups: [(parent: CallQualityIssue, children: [CallQualityIssue])] = [
        (.audio, [.audioStuttering, .audioLocalEcho, .audioRemoteEcho, .audioDrop]),
        (.video, [.videoNoCamera, .videoLowQuality, .videoLowResolution]),
        (.callDropped, []),
        (.other, []),
    ]
}

/// `CallQualitySurvey.Form`
public struct CallQualitySurveyForm: Sendable, Hashable {
    public var userSatisfied: Bool
    public var callQualityIssues: Set<CallQualityIssue>
    public var additionalIssuesDescription: String
    public var shareDebugLog: Bool
}

public struct CallQualitySurveyDialog: View {
    enum Page { case howWasYourCall, whatIssues, confirm }

    let onClose: () -> Void
    let onSubmit: (CallQualitySurveyForm) -> Void
    let onViewDebugLog: () -> Void
    let onViewDiagnosticInfo: () -> Void
    let isSubmitting: Bool
    @State var page = Page.howWasYourCall
    @State var userSatisfied: Bool?
    @State var issues: Set<CallQualityIssue> = []
    /// Per group: the sub-issues to restore when its parent is selected again.
    @State var stored: [CallQualityIssue: Set<CallQualityIssue>] = [:]
    @State var otherText = ""
    @State var userHasSeenOtherForm = false
    @State var shareDebugLog = false
    @FocusState var otherFocused: Bool
    @Environment(\.i18n) var i18n

    public init(onClose: @escaping () -> Void = {}, onSubmit: @escaping (CallQualitySurveyForm) -> Void = { _ in },
                onViewDebugLog: @escaping () -> Void = {}, onViewDiagnosticInfo: @escaping () -> Void = {}, isSubmitting: Bool = false) {
        self.onClose = onClose
        self.onSubmit = onSubmit
        self.onViewDebugLog = onViewDebugLog
        self.onViewDiagnosticInfo = onViewDiagnosticInfo
        self.isSubmitting = isSubmitting
    }

    var isOtherInputValid: Bool { !issues.contains(.other) || !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canContinue: Bool { !issues.isEmpty && isOtherInputValid }
    var showOtherInputError: Bool { userHasSeenOtherForm && !isOtherInputValid }

    func submit() {
        guard let userSatisfied else { return }
        onSubmit(CallQualitySurveyForm(userSatisfied: userSatisfied, callQualityIssues: issues, additionalIssuesDescription: otherText,
                                       shareDebugLog: shareDebugLog))
    }

    /// `IssueToggleGroup`: a parent toggles itself and restores (or drops) its sub-issues.
    func toggle(_ issue: CallQualityIssue, parent: CallQualityIssue?) {
        let on = !issues.contains(issue)
        if let parent {
            if on { issues.insert(issue); stored[parent, default: []].insert(issue) } else { issues.remove(issue); stored[parent]?.remove(issue) }
        } else {
            let children = CallQualityIssue.groups.first { $0.parent == issue }?.children ?? []
            if on { issues.insert(issue); issues.formUnion(stored[issue] ?? []) } else { issues.remove(issue); issues.subtract(children) }
            if issue == .other && !on { userHasSeenOtherForm = false }
        }
    }

    func description(_ key: String, centered: Bool = true) -> some View {
        CSSText(i18n(key), type: .bodyMedium, alignment: centered ? .center : .start, color: .labelPrimary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
    }

    public var body: some View {
        AxoDialog.Content(size: .md, hasFooter: page != .howWasYourCall) {
            switch page {
            case .howWasYourCall: howWasYourCall
            case .whatIssues: whatIssues
            case .confirm: confirm
            }
        }
    }

    @ViewBuilder var howWasYourCall: some View {
        AxoDialog.Header {
            AxoDialog.Title(i18n("icu:CallQualitySurvey__HowWasYourCall__PageTitle"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Body {
            description("icu:CallQualitySurvey__HowWasYourCall__PageDescription")
            HStack(spacing: 40) {
                BigCircleButton(symbol: "thumbsdown", background: .fillDestructiveTint, pressed: .fillDestructiveTintPressed, ink: .labelDestructive,
                                label: i18n("icu:CallQualitySurvey__HowWasYourCall__Response__HadIssues")) {
                    userSatisfied = false
                    page = .whatIssues
                }
                BigCircleButton(symbol: "thumbsup", background: .fillAccentTint, pressed: .fillAccentTintPressed, ink: .labelAccent,
                                label: i18n("icu:CallQualitySurvey__HowWasYourCall__Response__Great")) {
                    userSatisfied = true
                    page = .confirm
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder var whatIssues: some View {
        AxoDialog.Header {
            AxoDialog.Back { page = .howWasYourCall }
            AxoDialog.Title(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__PageTitle"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Body {
            description("icu:CallQualitySurvey__WhatIssuesDidYouHave__IssuesList__Heading")
            CSSFlex(.row, wrap: true, gap: 8, crossGap: 8, justify: .center) {
                ForEach(CallQualityIssue.groups, id: \.parent) { group in
                    issueToggle(group.parent, parent: nil)
                    if issues.contains(group.parent) {
                        ForEach(group.children, id: \.self) { issueToggle($0, parent: group.parent) }
                    }
                }
            }
            .padding(.horizontal, 16)
            if issues.contains(.other) { otherForm.padding(.top, 12) }
        }
        AxoDialog.Footer {
            AxoDialog.Actions {
                AxoButton.Root(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__ContinueButton"), variant: .strongPrimary, size: .md, width: .grow,
                               disabled: !canContinue) { page = .confirm }
                    .help(canContinue ? "" : i18n(isOtherInputValid ? "icu:CallQualitySurvey__WhatIssuesDidYouHave__ContinueButton__DisabledTooltip"
                                                  : "icu:CallQualitySurvey__WhatIssuesDidYouHave__SomethingElse__TextArea__ErrorText"))
            }
        }
    }

    func issueToggle(_ issue: CallQualityIssue, parent: CallQualityIssue?) -> some View {
        let selected = issues.contains(issue)
        return AxoButton.Root(i18n(issue.labelKey), variant: selected ? .strongPrimary : .strongSecondary, size: .md,
                              symbol: selected ? "check" : issue.symbol) { toggle(issue, parent: parent) }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The "Something else" textarea: field-sizing content between 80 and 200px, rounded-lg,
    /// a 0.5px border (error red once left empty), with its error and help text.
    var otherForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if otherText.isEmpty {
                    CSSText(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__SomethingElse__TextArea__Placeholder"), type: .bodyLarge,
                            color: .labelPlaceholder)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $otherText)
                    .font(.custom(AxoFonts.interName(weight: 400), size: 14))
                    .foregroundStyle(AxoColor.labelPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .focused($otherFocused)
                    .onChange(of: otherFocused) { _, now in if !now { userHasSeenOtherForm = true } }
                    .accessibilityLabel(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__SomethingElse__TextArea__AccessibilityLabel"))
            }
            .frame(minHeight: 80, maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .axoShadow(.shadowElevation1, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(showOtherInputError ? AxoColor.labelDestructive : AxoColor.borderPrimary, lineWidth: 0.5))
            .axoFocusRing(otherFocused, in: RoundedRectangle(cornerRadius: 12))
            if showOtherInputError {
                CSSText(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__SomethingElse__TextArea__ErrorText"), type: .bodySmall, color: .labelDestructive)
                    .padding(.top, 4).padding(.bottom, 12)
            }
            CSSText(i18n("icu:CallQualitySurvey__WhatIssuesDidYouHave__SomethingElse__TextArea__HelpText"), type: .bodySmall, color: .labelSecondary)
                .padding(.top, 12)
        }
    }

    @ViewBuilder var confirm: some View {
        AxoDialog.Header {
            AxoDialog.Back { page = userSatisfied == false ? .whatIssues : .howWasYourCall }
            AxoDialog.Title(i18n("icu:CallQualitySurvey__ConfirmSubmission__PageTitle"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Body {
            CSSText(runs: CSSTextRun.runs(i18n.richText("icu:CallQualitySurvey__ConfirmSubmission__PageDescriptionWithDiagnosticLink"),
                                          tags: ["diagnosticInfoLink": I18nTagStyle(color: .labelAccent, action: "diagnosticInfo")]),
                    style: CSSTextStyle(.bodyMedium), color: .labelPrimary) { _ in onViewDiagnosticInfo() }
                .padding(.bottom, 12)
            HStack(spacing: 12) {
                AxoCheckbox.Root(variant: .square, checked: $shareDebugLog,
                                 label: i18n("icu:CallQualitySurvey__ConfirmSubmission__ShareDebugLog__Label"))
                CSSText(i18n("icu:CallQualitySurvey__ConfirmSubmission__ShareDebugLog__Label"), type: .bodyMedium, wrap: .truncate, color: .labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { shareDebugLog.toggle() }
                AxoButton.Root(i18n("icu:CallQualitySurvey__ConfirmSubmission__ShareDebugLog__ViewButton"), variant: .subtlePrimary, size: .sm,
                               action: onViewDebugLog)
            }
            .padding(.vertical, 6)
            CSSText(i18n("icu:CallQualitySurvey__ConfirmSubmission__PrivacyNote"), type: .bodySmall, color: .labelSecondary)
                .padding(.top, 12)
        }
        AxoDialog.Footer {
            AxoDialog.Actions {
                AxoDialog.Action(i18n("icu:CallQualitySurvey__ConfirmSubmission__SubmitButton"), variant: .strongPrimary, pending: isSubmitting,
                                 action: submit)
            }
        }
    }
}

/// `BigCircleButton`: a 96px column — a 40px tinted circle with a 24px symbol, the label below.
struct BigCircleButton: View {
    let symbol: AxoSymbol.Name
    let background: AxoColor
    let pressed: AxoColor
    let ink: AxoColor
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                AxoSymbol.Icon(symbol, size: 24, label: nil)
                    .cssTextColor(ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(background))
                CSSText(label, type: .bodyMedium, alignment: .center, color: .labelPrimary)
            }
            .padding(12)
            .frame(width: 96)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(UndimmedButtonStyle())
    }
}

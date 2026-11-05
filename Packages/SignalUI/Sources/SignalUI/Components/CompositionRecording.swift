// Ports of ts/components/RecordingComposer.dom.tsx, CompositionRecording.dom.tsx and
// DiscardDraftDialog.dom.tsx (+ stylesheets/components/RecordingComposer.scss,
// CompositionRecording.scss): the voice-note recorder that replaces the composer while
// recording. A 34px incoming-surface pill (the red mic, the m:ss timer, the live level bars
// growing from the right) beside Cancel and Send. Escape cancels; leaving the app saves the
// recording as a draft; after an hour the recording stops with "Send anyway?".

import SignalI18n
import SwiftUI

/// `RecordingComposer`: the pill holding the recording UI, then Cancel and Send.
public struct RecordingComposer<Content: View>: View {
    let onCancel: () -> Void
    let onSend: () -> Void
    let content: Content
    @Environment(\.i18n) var i18n

    public init(onCancel: @escaping () -> Void, onSend: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onCancel = onCancel
        self.onSend = onSend
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 16).fill(AxoColor.surfaceMessageIncoming))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            AxoButton.Root(i18n("icu:RecordingComposer__cancel"), variant: .impliedSecondary, size: .md, action: onCancel)
            AxoButton.Root(i18n("icu:RecordingComposer__send"), variant: .strongPrimary, size: .md, action: onSend)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
    }
}

/// `ErrorDialogAudioRecorderType`
public enum ErrorDialogAudioRecorderType: Sendable { case timeout, errorRecording }

/// A recorder level sample (0…255) and its running index.
public struct RecordingPeak: Sendable, Hashable {
    public var value: Double
    public var index: Int
    public init(value: Double, index: Int) {
        self.value = value
        self.index = index
    }
}

public struct CompositionRecording: View {
    let peaks: [RecordingPeak]
    let errorDialog: ErrorDialogAudioRecorderType?
    let onCancel: () -> Void
    let onSend: () -> Void
    let errorRecording: (ErrorDialogAudioRecorderType) -> Void
    let saveDraftRecordingIfNeeded: () -> Void
    let startedAt: Date
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow

    public init(peaks: [RecordingPeak], errorDialog: ErrorDialogAudioRecorderType? = nil, startedAt: Date = .now,
                onCancel: @escaping () -> Void = {}, onSend: @escaping () -> Void = {},
                errorRecording: @escaping (ErrorDialogAudioRecorderType) -> Void = { _ in },
                saveDraftRecordingIfNeeded: @escaping () -> Void = {}) {
        self.peaks = peaks
        self.errorDialog = errorDialog
        self.startedAt = startedAt
        self.onCancel = onCancel
        self.onSend = onSend
        self.errorRecording = errorRecording
        self.saveDraftRecordingIfNeeded = saveDraftRecordingIfNeeded
    }

    public var body: some View {
        RecordingComposer(onCancel: onCancel, onSend: onSend) {
            // __microphone: mic-fill in accent red (pulsing)
            SignalIcon("v3/mic/mic-fill", size: 20, color: AxoColor(LegacyColor.accentRed), mask: true)
            if let fixedNow {
                timer(fixedNow.timeIntervalSince(startedAt))
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { ctx in timer(ctx.date.timeIntervalSince(startedAt)) }
            }
            levels
        }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in saveDraftRecordingIfNeeded() }
        .task(id: startedAt) {
            // Recordings stop at an hour.
            let remaining = 3600 - Date.now.timeIntervalSince(startedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if !Task.isCancelled { errorRecording(.timeout) }
        }
        .overlay { dialog }
    }

    /// `__timer`: min-width 40, end-aligned.
    func timer(_ seconds: TimeInterval) -> some View {
        CSSText(durationToPlaybackText(max(0, seconds)), style: LegacyType.body1(), wrap: .nowrap, alignment: .end)
            .frame(minWidth: 40, alignment: .trailing)
    }

    /// The level bars: newest on the right (row-reverse), 2px apart, each `value / 255` of the
    /// height plus 1px padding all round, in label-placeholder; older ones scroll off the left.
    var levels: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(peaks.reversed(), id: \.index) { p in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AxoColor.labelPlaceholder)
                        .frame(width: 2, height: max(0, geo.size.height * p.value / 255) + 2)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4).fill(AxoColor.surfaceMessageIncoming))
    }

    @ViewBuilder var dialog: some View {
        switch errorDialog {
        case .timeout:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: nil, description: i18n("icu:voiceRecordingInterruptedMax")) {
                    AxoConfirmDialog.Cancel(i18n("icu:discard"), action: onCancel)
                    AxoConfirmDialog.Action(i18n("icu:sendAnyway"), variant: .strongPrimary, action: onSend)
                }
            }
        case .errorRecording:
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: nil, description: i18n("icu:voiceNoteError")) {
                    AxoConfirmDialog.Action(i18n("icu:ok"), variant: .strongPrimary, action: onCancel)
                }
            }
        case nil:
            EmptyView()
        }
    }
}

/// `DiscardDraftDialog`: "Discard draft?" with Cancel and Discard.
public struct DiscardDraftDialog: View {
    let onClose: () -> Void
    let onDiscard: () -> Void
    @Environment(\.i18n) var i18n

    public init(onClose: @escaping () -> Void = {}, onDiscard: @escaping () -> Void = {}) {
        self.onClose = onClose
        self.onDiscard = onDiscard
    }

    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:DiscardDraftDialog__title"))
                AxoAlertDialog.Description(i18n("icu:DiscardDraftDialog__description"))
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Cancel(i18n("icu:cancel"), action: onClose)
                AxoAlertDialog.Action(i18n("icu:discard"), variant: .strongDestructive, action: onDiscard)
            }
        }
    }
}

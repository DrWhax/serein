// The single-message timeline notifications, each a SystemMessage (one file per upstream
// component is not worth it at this size; names and props follow upstream):
// VerificationNotification, ProfileChangeNotification, ChangeNumberNotification,
// ResetSessionNotification, JoinedSignalNotification, TitleTransitionNotification.

import SignalI18n
import SwiftUI

/// ts/components/conversation/VerificationNotification.dom.tsx
public struct VerificationNotification: View {
    public enum Kind: Sendable { case markVerified, markNotVerified }
    let type: Kind
    let isLocal: Bool
    let contactTitle: String
    @Environment(\.i18n) var i18n

    public init(type: Kind, isLocal: Bool, contactTitle: String) {
        self.type = type
        self.isLocal = isLocal
        self.contactTitle = contactTitle
    }

    public var body: some View {
        let key = switch (type, isLocal) {
        case (.markVerified, true): "icu:youMarkedAsVerified"
        case (.markVerified, false): "icu:youMarkedAsVerifiedOtherDevice"
        case (.markNotVerified, true): "icu:youMarkedAsNotVerified"
        case (.markNotVerified, false): "icu:youMarkedAsNotVerifiedOtherDevice"
        }
        // 'verified' and 'verified-not' share the safety-number icon.
        SystemMessage(.icon("v3/safety_number/safety_number-compact"),
                      contents: CSSTextRun.runs(i18n.richText(key, ["name": .element("name")]), elements: ["name": Emojify.run(contactTitle)]))
    }
}

/// ts/components/conversation/ProfileChangeNotification.dom.tsx (+ getStringForProfileChange):
/// the name change, with "Update" (edit nickname) when the contact has a nickname.
public struct ProfileChangeNotification: View {
    let oldName: String
    let newName: String
    let contactTitle: String
    /// `changedContact.name` (a system contact name): the message then names the contact.
    let contactName: String?
    let hasNickname: Bool
    let onOpenEditNicknameAndNoteModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(oldName: String, newName: String, contactTitle: String, contactName: String? = nil, hasNickname: Bool = false,
                onOpenEditNicknameAndNoteModal: @escaping () -> Void = {}) {
        self.oldName = oldName
        self.newName = newName
        self.contactTitle = contactTitle
        self.contactName = contactName
        self.hasNickname = hasNickname
        self.onOpenEditNicknameAndNoteModal = onOpenEditNicknameAndNoteModal
    }

    var message: String {
        contactName.map { $0.isEmpty ? nil : $0 } != nil
            ? i18n("icu:contactChangedProfileName", ["sender": .string(contactTitle), "oldProfile": .string(oldName), "newProfile": .string(newName)])
            : i18n("icu:changedProfileName", ["oldProfile": .string(oldName), "newProfile": .string(newName)])
    }

    public var body: some View {
        SystemMessage(.icon("v3/person/person-compact"), contents: [Emojify.run(message)]) {
            if hasNickname {
                LegacyButton(i18n("icu:update"), size: .small, variant: .systemMessage, action: onOpenEditNicknameAndNoteModal)
            }
        }
    }
}

/// The inline "&nbsp;·&nbsp;<MessageTimestamp>" ending ChangeNumber / JoinedSignal.
struct TimestampSuffix {
    static func runs(_ date: Date, now: Date, i18n: Localizer, timeZone: TimeZone) -> [CSSTextRun] {
        [CSSTextRun("\u{00A0}·\u{00A0}"), CSSTextRun(FormatTimestamp.time(date, now: now, i18n: i18n, timeZone: timeZone))]
    }
}

/// ts/components/conversation/ChangeNumberNotification.dom.tsx
public struct ChangeNumberNotification: View {
    let senderTitle: String
    let timestamp: Date
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    public init(senderTitle: String, timestamp: Date) {
        self.senderTitle = senderTitle
        self.timestamp = timestamp
    }

    public var body: some View {
        SystemMessage(.icon("v3/phone/phone-compact"),
                      contents: CSSTextRun.runs(i18n.richText("icu:ChangeNumber--notification", ["sender": .element("sender")]),
                                                elements: ["sender": Emojify.run(senderTitle)])
                        + TimestampSuffix.runs(timestamp, now: fixedNow ?? .now, i18n: i18n, timeZone: timeZone))
    }
}

/// ts/components/conversation/JoinedSignalNotification.dom.tsx
public struct JoinedSignalNotification: View {
    let timestamp: Date
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    public init(timestamp: Date) { self.timestamp = timestamp }

    public var body: some View {
        SystemMessage(.icon("v3/info/info-compact"),
                      contents: CSSTextRun.runs(i18n.richText("icu:JoinedSignal--notification"))
                        + TimestampSuffix.runs(timestamp, now: fixedNow ?? .now, i18n: i18n, timeZone: timeZone))
    }
}

/// ts/components/conversation/ResetSessionNotification.dom.tsx
public struct ResetSessionNotification: View {
    @Environment(\.i18n) var i18n
    public init() {}
    public var body: some View { SystemMessage(.icon("v3/refresh/refresh"), text: i18n("icu:sessionEnded")) }
}

/// ts/components/conversation/TitleTransitionNotification.dom.tsx
public struct TitleTransitionNotification: View {
    let oldTitle: String
    @Environment(\.i18n) var i18n
    public init(oldTitle: String) { self.oldTitle = oldTitle }
    public var body: some View {
        // `&--icon-thread` is declared twice; the later rule (v3/thread/thread.svg) wins.
        SystemMessage(.icon("v3/thread/thread"),
                      contents: CSSTextRun.runs(i18n.richText("icu:TitleTransition--notification", ["oldTitle": .element("oldTitle")]),
                                                elements: ["oldTitle": Emojify.run(oldTitle)]))
    }
}

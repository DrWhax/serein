// TimerNotification (ts/components/conversation/TimerNotification.dom.tsx): who set or
// turned off disappearing messages, with the timer / timer-slash icon.

import SignalI18n
import SwiftUI

public struct TimerNotification: View {
    public enum Source: Sendable { case fromOther, fromMe, fromSync, fromMember }
    let type: Source
    let title: String
    /// nil: disabled.
    let expireTimer: Int?
    @Environment(\.i18n) var i18n

    /// - Parameter expireTimer: seconds; nil when disappearing messages were turned off.
    public init(type: Source, title: String, expireTimer: Int?) {
        self.type = type
        self.title = title
        self.expireTimer = expireTimer
    }

    var contents: [CSSTextRun] {
        let disabled = expireTimer == nil
        let time = expireTimer.map { ExpirationTimer.format(i18n, $0) } ?? ""
        let name = Emojify.run(title)       // <ContactName title={title} />
        switch type {
        case .fromOther:
            return disabled
                ? CSSTextRun.runs(i18n.richText("icu:disabledDisappearingMessages", ["name": .element("name")]), elements: ["name": name])
                : CSSTextRun.runs(i18n.richText("icu:theyChangedTheTimer", ["name": .element("name"), "time": .string(time)]), elements: ["name": name])
        case .fromMe:
            return [CSSTextRun(disabled ? i18n("icu:youDisabledDisappearingMessages") : i18n("icu:youChangedTheTimer", ["time": .string(time)]))]
        case .fromSync:
            return [CSSTextRun(disabled ? i18n("icu:disappearingMessagesDisabled") : i18n("icu:timerSetOnSync", ["time": .string(time)]))]
        case .fromMember:
            return [CSSTextRun(disabled ? i18n("icu:disappearingMessagesDisabledByMember") : i18n("icu:timerSetByMember", ["time": .string(time)]))]
        }
    }

    public var body: some View {
        SystemMessage(.icon(expireTimer == nil ? "v3/timer/timer-slash-compact" : "v3/timer/timer-compact"), contents: contents)
    }
}

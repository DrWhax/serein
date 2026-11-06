// The button-toast rules (CallingToastManager.dom.tsx hooks) and the toast queue.

import Foundation
import SignalI18n
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingToastsTests {
    static let people: (UInt32) -> CallingButtonToasts.Person? = { id in
        switch id {
        case 1: CallingButtonToasts.Person(title: "Me", isMe: true, aci: "me")
        case 4: CallingButtonToasts.Person(title: "Participant 4", isMe: false, aci: "a4")
        case 5: CallingButtonToasts.Person(title: "Participant 5", isMe: false, aci: "a5")
        default: nil
        }
    }

    func texts(_ t: CallingButtonToasts) -> [String] {
        // (names are bidi-isolated: FSI … PDI)
        t.queue.toasts.map { if case .text(let s) = $0.content { s } else if case .raisedHand(let m, _, _) = $0.content { m } else { "" } }
            .map { $0.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "") }
    }

    @Test func rules() {
        let t = CallingButtonToasts(i18n: Localizer(locale: "en"), now: Date(timeIntervalSince1970: 0))
        let t0 = Date(timeIntervalSince1970: 10)
        t.update(.init(hasLocalAudio: true, outgoingRing: true), people: Self.people, localDemuxId: 1, now: t0)
        #expect(t.queue.toasts.isEmpty)     // the first state only sets the baseline
        t.update(.init(hasLocalAudio: false, outgoingRing: true), people: Self.people, localDemuxId: 1, now: t0)
        #expect(texts(t) == ["Mic off"])
        t.update(.init(hasLocalAudio: false, outgoingRing: false), people: Self.people, localDemuxId: 1, now: t0)
        #expect(t.queue.toasts.count == 1 && t.queue.toasts[0].key == "ringing")     // one button toast at a time
        t.update(.init(hasLocalAudio: false, outgoingRing: false, mutedBy: 4), people: Self.people, localDemuxId: 1, now: t0)
        #expect(texts(t) == ["Participant 4 muted you."])
        t.update(.init(hasLocalAudio: false, outgoingRing: false, mutedBy: 4, observedRemoteMute: ObservedRemoteMute(source: 4, target: 5)),
                 people: Self.people, localDemuxId: 1, now: t0)
        #expect(texts(t) == ["Participant 4 muted Participant 5."])
        t.update(.init(hasLocalAudio: false, outgoingRing: false, raisedHands: [4], mutedBy: 4, observedRemoteMute: ObservedRemoteMute(source: 4, target: 5)),
                 people: Self.people, localDemuxId: 1, now: t0)
        #expect(t.queue.toasts.first?.key == "raised-hands")
    }

    @Test func raisedHandsContent() {
        let i18n = Localizer(locale: "en")
        #expect(CallingButtonToasts.raisedHandsContent([1], people: Self.people, localDemuxId: 1, i18n: i18n) == nil)
        if case .raisedHand(_, _, let action)? = CallingButtonToasts.raisedHandsContent([4, 1], people: Self.people, localDemuxId: 1, i18n: i18n) {
            #expect(action == "lowerHand")
        } else { Issue.record("expected a toast") }
        if case .raisedHand(_, _, let action)? = CallingButtonToasts.raisedHandsContent([4, 5], people: Self.people, localDemuxId: 1, i18n: i18n) {
            #expect(action == "openQueue")
        } else { Issue.record("expected a toast") }
    }
}
